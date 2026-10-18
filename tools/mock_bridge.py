"""A dependency-free stand-in for `bridge.main --source mock`, speaking PROTOCOL.md v1.

The real mock needs the whole robot package (numpy, opencv, lerobot) and only runs on the
robot laptop. This needs nothing but `websockets`, so the Roblox side can be built and
verified on its own machine.

It is faithful where it matters and crude where it does not:
  * `hello` carries the real grid from robot/assets/workspace_sheet.json (3 rows x 4 cols,
    57.15 mm cells) -- so col/row derivation in Roblox is tested against the real numbers.
  * `arm.points` is a real 2-link-plus-azimuth FK chain in sheet mm, so the jaw actually
    arrives at the cell it is placing into. A sine-wave fake would not prove the mirror.
  * `blocks` carries stable ids, `level`, `held` and `visible`, and the default script runs
    Bay 1's exact solution: orange into B1, then two reds stacked into A4.

    Bay 1 wants obby cell (0,1) orange L1 and (3,0) red L2. With mat col = obby col + 1 and
    row A = obby row 0, that is mat B1 and mat A4.

    python mock_bridge.py [--host 0.0.0.0] [--port 8765] [--idle]
"""

import argparse
import asyncio
import json
import math
import time

import websockets

# ---------------------------------------------------------------- sheet geometry
# Straight from robot/assets/workspace_sheet.json. The sheet is LANDSCAPE: PROTOCOL.md's
# prose and hello example still say portrait with a 3x3 grid, which HANDOFF.md says was
# removed. The JSON spec and Main.server.lua's fitPad(279.4, 215.9) are the truth.
SHEET_W_MM, SHEET_H_MM = 279.4, 215.9
GRID_ORIGIN = (25.4, 22.225)
CELL_MM = 57.15
ROWS = ["A", "B", "C"]
COLS = [1, 2, 3, 4]
CUBE_MM = 48.0

# Centred off the top edge of a landscape sheet. The real server computes this from the arm's
# fitted calibration (Workspace.base_sheet_xy); PROTOCOL.md's 115.2 is a portrait-era figure.
ARM_BASE = (139.7, -44.5)

L1_MM, L2_MM = 142.46, 130.70   # Upper_arm_SO101, Under_arm_SO101
SHOULDER_Z = 120.0              # shoulder pitch axis height above the paper
PAN_Z = 69.0                    # pan axis height
WRIST_DROP = 60.0               # wrist_flex point down to the jaw tips

STATE_HZ = 30.0
EFFECTS = ["butterfingers", "earthquake", "fog", "freeze", "mirror", "molasses"]
JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]


def cell_centre(row_letter, col_number):
    r, c = ROWS.index(row_letter), COLS.index(col_number)
    return (GRID_ORIGIN[0] + (c + 0.5) * CELL_MM,
            GRID_ORIGIN[1] + (r + 0.5) * CELL_MM)


# ---------------------------------------------------------------- arm
def fk_points(target):
    """A plausible stick figure whose jaw tips land exactly on `target` (sheet mm).

    Solves azimuth, then a 2-link planar arm in the vertical plane through that azimuth,
    aiming at a wrist point WRIST_DROP above the target so the jaw hangs straight down.
    """
    tx, ty, tz = target
    bx, by = ARM_BASE
    pan = math.atan2(ty - by, tx - bx)

    wx, wy, wz = tx, ty, tz + WRIST_DROP
    r = math.hypot(wx - bx, wy - by)
    dz = wz - SHOULDER_Z
    d = math.hypot(r, dz)
    d = min(d, (L1_MM + L2_MM) * 0.999)       # keep the triangle solvable

    # Law of cosines for the shoulder-lift and elbow interior angles.
    cos_elbow = (L1_MM**2 + L2_MM**2 - d**2) / (2 * L1_MM * L2_MM)
    elbow = math.acos(max(-1.0, min(1.0, cos_elbow)))
    cos_a = (L1_MM**2 + d**2 - L2_MM**2) / (2 * L1_MM * d)
    a = math.acos(max(-1.0, min(1.0, cos_a)))
    lift = math.atan2(dz, r) + a

    sx, sy = bx, by
    ex = sx + L1_MM * math.cos(lift) * math.cos(pan)
    ey = sy + L1_MM * math.cos(lift) * math.sin(pan)
    ez = SHOULDER_Z + L1_MM * math.sin(lift)

    pts = [
        ("shoulder_pan", bx, by, PAN_Z),
        ("shoulder_lift", sx, sy, SHOULDER_Z),
        ("elbow_flex", ex, ey, ez),
        ("wrist_flex", wx, wy, wz),
        ("wrist_roll", tx, ty, tz + WRIST_DROP * 0.45),
        ("tip", tx, ty, tz),
    ]
    angles = {
        "shoulder_pan": math.degrees(pan),
        "shoulder_lift": math.degrees(lift),
        "elbow_flex": math.degrees(elbow),
        "wrist_flex": -math.degrees(lift) - math.degrees(elbow),
        "wrist_roll": 0.0,
    }
    return [{"name": n, "x": round(x, 1), "y": round(y, 1), "z": round(z, 1)}
            for n, x, y, z in pts], angles


# ---------------------------------------------------------------- blocks
TRAY_X = 266.0      # on the sheet but past the grid's right edge, so _cell_of -> None


class Block:
    def __init__(self, bid, color, x, y):
        self.id, self.color = bid, color
        self.x, self.y, self.z = x, y, 0.0
        self.level, self.held, self.visible = 0, False, True

    def json(self):
        return {"id": self.id, "color": self.color,
                "x": round(self.x, 1), "y": round(self.y, 1), "z": round(self.z, 1),
                "yaw": 0.0, "level": self.level,
                # A held block reports grey: FK knows where the jaw is, not what is in it.
                "color_held": None, "held": self.held,
                "visible": self.visible, "age": 0.0}


class World:
    def __init__(self, idle=False, bay=1):
        self.bay = bay
        self.blocks = [
            Block(1, "orange", TRAY_X, 40.0),
            Block(2, "orange", TRAY_X, 80.0),
            Block(3, "red", TRAY_X, 120.0),
            Block(4, "red", TRAY_X, 160.0),
        ]
        self.tip = (ARM_BASE[0], 40.0, 180.0)
        self.note = "idle" if idle else "starting"
        self.idle = idle
        self.carrying = None

    def by_id(self, bid):
        return next(b for b in self.blocks if b.id == bid)

    def frame(self, seq):
        pts, angles = fk_points(self.tip)
        grip = 18.0 if self.carrying else 55.0
        angles["gripper"] = grip
        blocks = []
        for b in self.blocks:
            j = b.json()
            j.pop("color_held")
            if b.held:
                j["color"] = "grey"      # see PROTOCOL.md: carried, colour not measured
            blocks.append(j)
        return {
            "t": "state", "seq": seq, "ts": round(time.time(), 2),
            "arm": {"joints": {k: round(v, 1) for k, v in angles.items()},
                    "points": pts,
                    "tip": {"x": pts[-1]["x"], "y": pts[-1]["y"], "z": pts[-1]["z"]}},
            "arm_age": 0.03,
            "blocks": blocks, "blocks_age": 0.09,
            "effects": [],
            "notes": {"script": self.note},
        }


def hello():
    return {
        "t": "hello", "v": 1, "source": "mock", "state_hz": STATE_HZ,
        "joints": JOINTS, "effects": EFFECTS,
        "space": {
            "frame": "sheet mm: origin at the sheet's top-left corner, +x right, +y down "
                     "the page (away from the arm), +z up off the paper",
            "sheet": {"w_mm": SHEET_W_MM, "h_mm": SHEET_H_MM},
            "grid": {"origin_mm": list(GRID_ORIGIN), "cell_mm": CELL_MM,
                     "rows": ROWS, "cols": COLS,
                     "naming": "letter is the row (A nearest the arm), number is the column"},
            "cube_mm": CUBE_MM,
            "arm_base_mm": list(ARM_BASE),
            "suggest": {"studs_per_mm": 0.46, "level_studs": 6.5},
        },
    }


# ---------------------------------------------------------------- the script
async def glide(world, to, seconds=1.2):
    """Move the jaw to `to` over `seconds`, dragging a carried block with it."""
    start, steps = world.tip, max(1, int(seconds * STATE_HZ))
    for i in range(1, steps + 1):
        k = i / steps
        world.tip = tuple(start[j] + (to[j] - start[j]) * k for j in range(3))
        if world.carrying is not None:
            b = world.by_id(world.carrying)
            b.x, b.y, b.z = world.tip[0], world.tip[1], max(0.0, world.tip[2])
        await asyncio.sleep(1 / STATE_HZ)


async def pick_and_place(world, bid, row, col, level):
    b = world.by_id(bid)
    cx, cy = cell_centre(row, col)
    rest = level * CUBE_MM

    world.note = f"reaching for block {bid}"
    await glide(world, (b.x, b.y, 140.0))
    await glide(world, (b.x, b.y, CUBE_MM * 0.5), 0.8)

    world.note = f"carrying block {bid} to {row}{col}"
    world.carrying, b.held = bid, True
    await glide(world, (b.x, b.y, 150.0), 0.6)
    await glide(world, (cx, cy, 150.0), 1.6)
    await glide(world, (cx, cy, rest + CUBE_MM * 0.5), 0.9)

    world.carrying, b.held = None, False
    b.x, b.y, b.z, b.level = cx, cy, rest, level     # resting: snapped to the cell centre
    world.note = f"placed block {bid} at {row}{col} L{level}"
    await glide(world, (cx, cy, 150.0), 0.6)


# Bay 2 (Void) is a PLACEMENT bay: filling its solveCells is the win condition, unlike Bay 1
# whose crates are only a ladder. Scripting it proves the whole live chain -- blocks -> derived
# cells -> HazardManager.checkSolved -> SOLVED -- which Bay 1 structurally cannot, because
# switch-mode bays skip checkSolved entirely.
#
# BayData[2] wants red L1 in obby cells (1,0) and (1,1). With mat col = obby col + 1 and row A
# = obby row 0, that is mat A2 and B2.
BAY_SCRIPTS = {
    1: [(1, "B", 1, 0), (3, "A", 4, 0), (4, "A", 4, 1)],
    2: [(3, "A", 2, 0), (4, "B", 2, 0)],
}


async def run_script(world):
    if world.idle:
        world.note = "idle"
        while True:
            t = time.time()
            world.tip = (ARM_BASE[0] + 60 * math.sin(t * 0.3),
                         90 + 40 * math.sin(t * 0.21),
                         120 + 30 * math.sin(t * 0.4))
            await asyncio.sleep(1 / STATE_HZ)

    await asyncio.sleep(2.0)
    steps = BAY_SCRIPTS[world.bay]
    while True:
        for bid, row, col, level in steps:
            await pick_and_place(world, bid, row, col, level)
        world.note = f"bay {world.bay} solved; holding"
        await asyncio.sleep(6.0)

        world.note = "sweeping the mat for the next bay"
        for b in world.blocks:                        # the sweep that must not un-solve a bay
            b.x, b.y, b.z, b.level = TRAY_X, 40.0 + 40 * (b.id - 1), 0.0, 0
        await asyncio.sleep(3.0)


# ---------------------------------------------------------------- server
async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--idle", action="store_true", help="just wave the arm, place nothing")
    ap.add_argument("--bay", type=int, default=1, choices=[1, 2],
                    help="which bay's solution to script (1 = saw wall, 2 = void)")
    args = ap.parse_args()

    world = World(idle=args.idle, bay=args.bay)
    clients = set()

    async def serve(sock):
        clients.add(sock)
        peer = getattr(sock, "remote_address", None)
        print(f"[mock] client connected: {peer}  ({len(clients)} total)")
        await sock.send(json.dumps(hello()))
        try:
            async for raw in sock:
                try:
                    frame = json.loads(raw)
                except Exception:
                    await sock.send(json.dumps({"t": "error",
                                                "message": "undecodable", "frame": None}))
                    continue
                t = frame.get("t")
                if t == "ping":
                    await sock.send(json.dumps({"t": "pong", "id": frame.get("id"),
                                                "ts": round(time.time(), 1)}))
                elif t == "event":
                    name = frame.get("name")
                    if name in EFFECTS:
                        print(f"[mock] <- event {name} "
                              f"intensity={frame.get('intensity')} duration={frame.get('duration')}")
                    else:
                        print(f"[mock] <- unknown effect {name!r}")
                        await sock.send(json.dumps(
                            {"t": "error", "message": f"unknown effect {name!r}", "frame": None}))
                elif t == "mode":
                    print(f"[mock] <- mode {frame.get('name')} level={frame.get('level')}")
                else:
                    print(f"[mock] <- {t}")
        except Exception as exc:
            print(f"[mock] client error: {exc}")
        finally:
            clients.discard(sock)
            print(f"[mock] client gone ({len(clients)} left)")

    async def broadcast():
        seq = 0
        while True:
            seq += 1
            payload = json.dumps(world.frame(seq))
            for sock in list(clients):
                try:
                    await sock.send(payload)
                except Exception:
                    clients.discard(sock)
            if seq % 300 == 0:
                print(f"[mock] seq={seq} clients={len(clients)} note={world.note!r}")
            await asyncio.sleep(1 / STATE_HZ)

    async with websockets.serve(serve, args.host, args.port, ping_interval=None):
        print(f"[mock] protocol v1 on ws://{args.host}:{args.port}  "
              f"({'idle' if args.idle else 'bay 1 script'}) -- ctrl-c to stop")
        await asyncio.gather(broadcast(), run_script(world))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[mock] stopped")
