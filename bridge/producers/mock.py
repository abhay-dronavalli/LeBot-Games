"""The whole rig, faked, so Roblox work never waits on hardware.

This is deliberately not sine waves on invented link lengths. It drives the *real* inverse
kinematics and the *real* fitted calibration through a scripted pick, carry and stack, and it
hides a block from the fake camera exactly when the jaw closes over it. So the mock exercises
every path the live rig does, including the two that are easy to get wrong and impossible to
test by hand: held-block tracking and stack levels.

What you see in the viewer is therefore the crane lift, before the arm is ever plugged in.

    python -m bridge.main --source mock

The cycle: pick the red block out of cell A1, carry it 150 mm up and across the sheet, stack
it on the teal block in C3, then come back and put it where it started. Repeat.
"""

import json
import math
import time

import numpy as np

from robot.perception.config import SHEET_SPEC
from robot.workspace import Workspace

from . import arm as arm_mod
from .arm import arm_frame

GRIPPER_OPEN = 50.0
GRIPPER_CLOSED = 20.0      # on a 48 mm cube; see world.GRIP_CLOSED_PCT
CARRY_H = 150.0
HOVER_H = 110.0
GRASP_H = 14.0
STACK_H = 62.0             # one cube up, plus a release gap
PRECISE_BELOW_MM = 60.0    # below this the jaw must be near-vertical (robot/skills.py)
NEAR_EDGE_MM = 85.0        # synthetic placement: grid's near edge this far out from the
                           # pan axis. Verified by sweeping the reach envelope.

# The grid comes from assets/workspace_sheet.json, so regenerating the sheet with
# robot/scripts/make_sheet.py moves the mock's pick and place targets with it instead of
# leaving them pointing at cells that no longer exist.
_SPEC = json.loads(SHEET_SPEC.read_text())
_GRID = _SPEC["grid"]
GRID_ORIGIN = tuple(_GRID["origin_mm"])
CELL_MM = _GRID["cell_mm"]
_ROWS = [str(r) for r in _GRID["rows"]]


def cell(name):
    """"A1" -> sheet mm centre. Letter is the row (A nearest the arm), number the column."""
    row = _ROWS.index(name[0].upper())
    col = int(name[1:]) - 1
    return (GRID_ORIGIN[0] + (col + 0.5) * CELL_MM, GRID_ORIGIN[1] + (row + 0.5) * CELL_MM)


# Pick from the near-left cell and stack on the far-right one, whatever the grid's shape.
A1 = cell(f"{_ROWS[0]}1")
C3 = cell(f"{_ROWS[-1]}{len(_GRID['cols'])}")
PARK = (_SPEC["sheet"]["w_mm"] / 2, _SPEC["sheet"]["h_mm"] / 2) if "sheet" in _SPEC \
    else (115.0, 140.0)

# (label, tip xy, height mm, gripper, seconds to get there, action)
# action: None | ("grab",) | ("release",)
SCRIPT = [
    ("park",        PARK, CARRY_H, GRIPPER_OPEN,    1.2, None),
    ("over A1",     A1,   HOVER_H, GRIPPER_OPEN,    1.5, None),
    ("descend",     A1,   GRASP_H, GRIPPER_OPEN,    1.0, None),
    ("close jaw",   A1,   GRASP_H, GRIPPER_CLOSED,  0.6, ("grab",)),
    ("lift",        A1,   CARRY_H, GRIPPER_CLOSED,  1.0, None),
    ("carry to C3", C3,   CARRY_H, GRIPPER_CLOSED,  2.5, None),
    ("lower on C3", C3,   STACK_H, GRIPPER_CLOSED,  1.0, None),
    ("let go",      C3,   STACK_H, GRIPPER_OPEN,    0.6, ("release",)),
    ("retreat",     C3,   CARRY_H, GRIPPER_OPEN,    1.0, None),
    # ...and put it back, so the loop is a closed cycle and the demo can run unattended.
    ("re-descend",  C3,   STACK_H, GRIPPER_OPEN,    1.2, None),
    ("re-grip",     C3,   STACK_H, GRIPPER_CLOSED,  0.6, ("grab",)),
    ("lift again",  C3,   CARRY_H, GRIPPER_CLOSED,  1.0, None),
    ("carry to A1", A1,   CARRY_H, GRIPPER_CLOSED,  2.5, None),
    ("lower on A1", A1,   GRASP_H + 4, GRIPPER_CLOSED, 1.0, None),
    ("drop",        A1,   GRASP_H + 4, GRIPPER_OPEN, 0.6, ("release",)),
    ("clear",       A1,   CARRY_H, GRIPPER_OPEN,    1.0, None),
]

STACK_XY_MM = 35.0         # matches world.STACK_XY_MM


def _ease(u):
    """Smooth start and stop, so the fake arm does not look like a metronome."""
    return 0.5 - 0.5 * math.cos(math.pi * min(max(u, 0.0), 1.0))


class MockRig:
    """Solves the script once, then replays it. IK is too slow to run per tick."""

    def __init__(self, blocks=None):
        self.ws = Workspace()
        self.synthetic = self._place_sheet_if_unreachable()
        self.blocks = dict(blocks or {"red_cube": list(A1), "teal_cube": list(C3)})
        # Later in the list means resting on top. The fake camera only reports the top of a
        # stack, which is what an overhead camera actually sees.
        self.order = list(self.blocks)
        self.grabbed = None
        self.keys = self._solve_script()
        self.total = sum(step[4] for step in SCRIPT)
        self.label = SCRIPT[0][0]

    def _place_sheet_if_unreachable(self):
        """Put the sheet somewhere the arm can reach, if the real calibration cannot.

        Mock mode exists so Roblox work never waits on hardware. But it runs the real IK
        against `robot/calibration/arm_sheet_calibration.json`, whose `sheet_to_base` is only
        valid while the arm and the sheet are physically where they were when it was fitted.
        Re-generate the sheet, or move anything, and that transform describes a layout that no
        longer exists, so the mock's targets land outside the arm's envelope and the demo
        quietly degrades to a twitch.

        So: if the grid is not reachable, synthesise a placement. `theta` is kept, because it
        encodes how the arm is actually bolted down, and only the translation is solved, to
        centre the grid across the arm with its near edge a reachable distance out. Positions
        stay honest sheet millimetres; only the pretend location of the paper changes.
        """
        if self._grid_reachable():
            return False
        want_x = GRID_ORIGIN[0] + len(_GRID["cols"]) * CELL_MM / 2
        want_y = GRID_ORIGIN[1] - NEAR_EDGE_MM
        t = math.radians(self.ws.theta)
        R = np.array([[math.cos(t), -math.sin(t)], [math.sin(t), math.cos(t)]])
        pan_xy = self.ws.kin.chain[0]["origin"][:2, 3]
        tx, ty = pan_xy - R @ np.array([want_x, -want_y])
        self.ws.tx, self.ws.ty = float(tx), float(ty)
        return True

    def _grid_reachable(self):
        """Can the arm put a block in every cell, on the table and two blocks up?"""
        for r in range(len(_GRID["rows"])):
            for c in range(len(_GRID["cols"])):
                p = (GRID_ORIGIN[0] + (c + .5) * CELL_MM, GRID_ORIGIN[1] + (r + .5) * CELL_MM)
                for h, tilt in ((GRASP_H, 25.0), (STACK_H, 60.0)):
                    try:
                        self.ws.solve(p, h, max_tilt_deg=tilt)
                    except ValueError:
                        return False
        return True

    def _solve_script(self):
        """Joint readings for each keyframe. Unreachable frames fall back to the last good
        one rather than crashing: the mock must always start, even on a stale calibration."""
        seed = None
        out = []
        for label, xy, h, grip, _secs, _action in SCRIPT:
            try:
                # Near the table the jaw must be near-vertical to close on a cube's faces;
                # higher up nothing is being grasped, so tilt is free. robot/skills.py draws
                # the same line at PRECISE_BELOW_MM. Without this, a carry pose over A1 (the
                # cell closest to the base) is "unreachable" at 28 deg of tilt.
                tilt = 25.0 if h < PRECISE_BELOW_MM else 60.0
                reading = self.ws.solve(xy, h, seed_reading=seed, max_tilt_deg=tilt)
                seed = reading
            except ValueError as e:
                if not out:
                    raise SystemExit(
                        f"mock: cannot solve the first keyframe ({label}): {e}\n"
                        "The sheet-to-base calibration is probably stale; see "
                        "robot/calibration/README.md.")
                print(f"  mock: keyframe {label!r} unreachable ({e}); holding the previous pose")
                reading = dict(out[-1][0])
            out.append((dict(reading), grip, label))
        return out

    def at(self, t):
        """The joint reading, gripper and label at time t seconds into a looping cycle."""
        t = t % self.total
        acc = 0.0
        for i, (_label, _xy, _h, _grip, secs, action) in enumerate(SCRIPT):
            if t < acc + secs:
                u = _ease((t - acc) / secs)
                a_reading, a_grip, _ = self.keys[i - 1] if i else self.keys[-1]
                b_reading, b_grip, label = self.keys[i]
                reading = {j: a_reading[j] + (b_reading[j] - a_reading[j]) * u for j in a_reading}
                reading["gripper"] = a_grip + (b_grip - a_grip) * u
                return reading, label, (action if u > 0.5 else None)
            acc += secs
        reading, grip, label = self.keys[-1]
        reading = dict(reading)
        reading["gripper"] = grip
        return reading, label, None

    def step(self, t, effects=None, t_wall=None):
        """Advance the fake world. Returns (arm frame, fake detections).

        `effects` bends the scripted pose exactly as it bends the leader's command on real
        hardware, so an earthquake sent from the viewer shakes the mock arm.
        """
        reading, label, action = self.at(t)
        self.label = label
        if effects is not None:
            commanded = effects.apply({f"{j}.pos": v for j, v in reading.items()},
                                      t if t_wall is None else t_wall)
            reading = {k.removesuffix(".pos"): v for k, v in commanded.items()}
        frame = arm_frame(self.ws, reading, extra={"script": label, "mock": True})
        tip = frame["tip"]

        if action == ("grab",) and self.grabbed is None:
            near = self._topmost_near(tip["x"], tip["y"])
            if near:
                self.grabbed = near
        elif action == ("release",) and self.grabbed is not None:
            self.blocks[self.grabbed] = [tip["x"], tip["y"]]
            self.order.remove(self.grabbed)
            self.order.append(self.grabbed)       # released last, so it rests on top
            self.grabbed = None

        if self.grabbed is not None:
            self.blocks[self.grabbed] = [tip["x"], tip["y"]]

        return frame, self._detections()

    def _topmost_near(self, x, y):
        for name in reversed(self.order):
            bx, by = self.blocks[name]
            if math.hypot(bx - x, by - y) <= STACK_XY_MM:
                return name
        return None

    def _detections(self):
        """What the fake overhead camera reports: every block except the one in the jaw, and
        only the top of each stack. Those two omissions are the whole reason world.py exists,
        so the mock has to reproduce them or it tests nothing."""
        out = []
        for name in self.order:
            if name == self.grabbed:
                continue                                  # the jaw covers it
            x, y = self.blocks[name]
            if any(other != name and other != self.grabbed
                   and self.order.index(other) > self.order.index(name)
                   and math.hypot(self.blocks[other][0] - x, self.blocks[other][1] - y) <= STACK_XY_MM
                   for other in self.order):
                continue                                  # a block above it hides it
            out.append({"name": name, "center_mm": [round(x, 1), round(y, 1)],
                        "yaw_deg": 0.0, "score": 0.9})
        return out


def run(bus, tracker, inbox, effects, stop, hz=30.0):
    """Producer thread: fake arm and fake camera into the bus. Same signature as teleop.run."""
    rig = MockRig()
    print(f"mock: {len(SCRIPT)} keyframes solved, cycle is {rig.total:.1f} s")
    if rig.synthetic:
        print("mock: the real sheet-to-base calibration cannot reach this grid, so the "
              "sheet is placed\n      synthetically. Fine for Roblox work; re-run "
              "robot.scripts.calibration.touch_calibrate\n      before trusting the arm.")
    period = 1.0 / hz
    t0 = time.perf_counter()
    while not stop.is_set():
        loop = time.perf_counter()
        now = loop - t0

        for frame in inbox.drain({"event"}):
            got = effects.add(frame.get("name"), frame.get("intensity", 1.0),
                              frame.get("duration", 3.0))
            if got:
                print(f"  mock: effect {frame['name']} {got[0]:.2f} for {got[1]:.1f} s")

        # Effects run in mock mode too, on the same code path as teleop: the fake arm
        # visibly shakes, lags, mirrors and freezes. Without this the whole Roblox-to-robot
        # direction would be untestable until the hardware is plugged in, and `apply` is
        # also what expires a finished effect.
        arm, detections = rig.step(now, effects=effects, t_wall=loop)
        bus.publish_arm(arm)
        bus.publish_blocks(tracker.update(detections, arm, time.time()))
        bus.note("script", rig.label)

        sleep = period - (time.perf_counter() - loop)
        if sleep > 0:
            time.sleep(sleep)
