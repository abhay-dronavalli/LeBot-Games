# Robo-Obby: Real Robot × Roblox — Hackathon Plan

**One-liner:** A Roblox player and a real robot-arm operator play together, and each one changes the other's world. Blocks the arm moves on a real table become platforms, stairs and elevators in Roblox. Events in Roblox (earthquakes, fog, power-ups) make the real arm shake, lag, or freeze.

**Hardware:** SO-101 leader + follower pair (LeRobot), one webcam on an overhead tripod, a laptop.
**Time budget:** 24–36 hours. **Priority:** flashiest features first, then as many modes as time allows.

---

## 0. Decisions made (change these if they're wrong)

| Question | Default chosen | Why |
|---|---|---|
| Arm | "S101" = **SO-101 leader + follower** | Matches the leader/follower teleop described |
| How Roblox runs | **Studio Play mode on a laptop on the same network as the robot laptop** | Roblox WebSockets (`CreateWebStreamClient`) only work in Studio and are blocked in live games. Studio gives real-time, two-way messaging. A published game is limited to polling (500 HTTP requests/min per server) through a public tunnel. |
| Fallback | HTTP polling endpoint with the same JSON | Lets you switch to a published game later by changing one setting |
| Blocks | **6–10 small cubes (3–4 cm, test that the gripper can hold them) with the same ArUco marker printed on all 6 faces** | Overhead tracking is reliable, and a block stays identifiable after it flips. Painted colors give humans a name for each block ("the red one"). |
| Build order | Sky Arm → Obby (+ crane lift) → Two-way events → 1v1 Arena → Pattern Match | Each step reuses the one before it, and you can demo something real at every checkpoint |

---

## 1. Game modes (ranked by flash-per-hour)

### Core feature in every mode: the Sky Arm
A giant SO-101 hangs over the map and mirrors the real follower's joints live. When the real arm holds a block, the giant arm holds a giant ghost block. When the block is released, a light beam drops to where the platform spawns. This is the "wow" moment that connects the real and virtual worlds, and it costs little once joint angles are streaming.

### Mode A — Obby (flagship)
The player spawns, faces obstacles they cannot clear alone, and the arm operator builds the way across.

Level ideas, each teaching one mechanic:
1. **The Gap** (tutorial): too wide to jump. Place one block, and a bridge platform appears.
2. **The Wall**: 2–3 blocks tall. Stack blocks into a staircase. Stack height in real life equals step height in game.
3. **The Lava Lake / Crane Lift** (money shot): the player stands on a block-platform. The operator lifts the real block and carries it over the lava, carrying the player with it.
4. **Pressure Plates**: put a block on a marked spot on the real table to open a door in game (table zones act as triggers).
5. **Laser Hall** (stretch): hold a block in the air as a moving shield that blocks laser beams.

**Scale rule:** pick the studs-per-cm scale so that **one block height is just under the default jump height (~7 studs)**. Then one block is a jumpable step and a 3-block wall is not. Design obstacles in "block units."

**Level ↔ table mapping:** the table play area maps onto the *current level's build zone*. When the player enters level N, the mapping origin moves to level N. A taped "inventory tray" strip on the table maps to nothing, so blocks parked there don't spawn. The operator resets blocks to the tray between levels.

### Mode B — Two-way events (spans all modes)
Roblox → real arm (applied as modifiers in the teleop loop):

| In-game event | What happens in Roblox | What happens to the real arm |
|---|---|---|
| Earthquake | Camera shake, platforms jitter | Follower shakes (small sine wave + noise on pan/wrist) |
| Fog | Fog rolls in | Follower lags 300–800 ms behind the leader |
| Mirror World | Screen flips | Shoulder pan is inverted |
| Molasses | Slow-motion effect | Follower is low-pass filtered (sluggish) |
| Butterfingers | Warning icon | Gripper can't fully close (block may slip; test carefully) |
| Freeze (1v1 power-up) | Arm turns to ice | Follower holds its position for 2–3 s |

Triggers: timers, "DON'T PRESS" buttons in the map, or player power-ups. Real → Roblox happens automatically through block and arm state.

### Mode C — 1v1 Arena (cheap once the Sky Arm works)
- A ground-level giant arm in an arena mirrors the follower. Links touching the player cause knockback or damage.
- **Grab:** if the gripper closes around the player, the player is caught, lifted and dropped. Very flashy.
- The player wins by surviving 60 s and hitting 3 buttons. Each button triggers a real-world penalty (Freeze, Mirror, Fog).
- Real blocks on the table become walls in the arena (reuses block sync), so the operator can trap the player.

### Mode D — Pattern Match (cheap once vision works)
- A printed 3×3 grid on the table. The Roblox player sees a target pattern (which colored block goes in which cell, possibly stacked). The operator can't see it and only hears callouts.
- Python checks the detected layout against the target. Timer, multiple rounds, increasing difficulty.
- Twist so the Roblox player also has to *play*: pieces of the pattern are scattered across a small map, so they have to run around (or parkour) to read them while calling them out.
- The Roblox screen shows a live replica of the table so the player can say "move the red one left."

---

## 2. Architecture

```
 ┌────────────── Robot laptop (Python) ────────────────┐
 │                                                       │
 │  robot_loop (thread, 30 Hz)                           │
 │    leader.get_action() → effects.apply() → clamp      │
 │    → follower.send_action() → follower.get_observation│
 │                         │ joint angles                │
 │  vision (thread, 30 Hz) │                             │
 │    webcam → ArUco → homography → block poses          │
 │                         ▼                             │
 │  world.py  — merges vision + FK (held/stacked blocks) │
 │            — table cm → game coordinates              │
 │                         │                             │
 │  ws_server (asyncio) ◄──┘  broadcasts state @ 20–30 Hz │
 │    + HTTP fallback: GET /state, POST /event            │
 └──────────────────────────┬────────────────────────────┘
                            │ WebSocket (LAN or localhost)
 ┌──────────────────────────▼────────────────────────────┐
 │  Roblox Studio (server scripts)                        │
 │    Bridge → StateStore (latest + interpolation)        │
 │    SkyArm rig · BlockSync (platforms) · Modes · Events │
 │    Events ──► ws:Send({t="event", ...}) ──► Python      │
 └────────────────────────────────────────────────────────┘
```

### Message protocol (JSON)
Python → Roblox, ~20–30 Hz:
```json
{"t":"state","seq":1042,"ts":1760700000.12,
 "arm":{"shoulder_pan":12.1,"shoulder_lift":-40.3,"elbow_flex":55.0,
        "wrist_flex":20.2,"wrist_roll":-3.0,"gripper":34.0},
 "tip":{"x":21.5,"y":30.2,"z":8.1},
 "blocks":[{"id":11,"color":"red","x":12.1,"y":40.2,"z":0.0,"yaw":15,
            "level":0,"held":false,"visible":true,"zone":"play"}]}
```
Roblox → Python:
```json
{"t":"event","name":"earthquake","intensity":0.7,"duration":4}
{"t":"mode","name":"obby","level":3}
{"t":"pattern","target":[[11,null,12],[null,13,null],[null,null,null]]}
```
Units: table frame in **cm** (origin = corner marker 0, x across, y away from the operator, z up). Roblox does the cm→stud conversion so the scale can be tuned without restarting Python.

---

## 3. Components

### 3.1 Robot loop + effects (`server/robot_loop.py`, `server/effects.py`)
Sketch only; check imports against your installed LeRobot. Recent versions use `so_follower`/`so_leader`, while older ones use `so101_follower`/`so101_leader`. **Pin the version on day one.**
```python
from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
from lerobot.teleoperators.so_leader import SO101Leader, SO101LeaderConfig

follower = SO101Follower(SO101FollowerConfig(port=FOLLOWER_PORT, id="follower"))
leader   = SO101Leader(SO101LeaderConfig(port=LEADER_PORT, id="leader"))
follower.connect(); leader.connect()

while running:
    action = leader.get_action()            # {"shoulder_pan.pos": ..., ...}
    action = effects.apply(action, now())   # earthquake / lag / mirror / freeze
    action = clamp_to_safe_ranges(action)
    follower.send_action(action)
    obs = follower.get_observation()        # actual positions → Roblox
    shared.arm = {k.removesuffix(".pos"): v for k, v in obs.items() if k.endswith(".pos")}
    sleep_until_next_tick(hz=30)
```
- **Don't** attach the webcam to the robot config; run vision in its own thread.
- Joint units: check whether your version reports normalized values (−100..100) or degrees (some versions have a `use_degrees` option). Roblox needs angles, so convert once in Python.
- Effects form a list of active modifiers, each with `(start, duration, intensity)`. They stack and expire on their own.
- **Safety (non-negotiable):**
  - Set `max_relative_target` in the follower config (limits the per-step jump).
  - Clamp every joint to a calibrated safe range.
  - Cap earthquake amplitude to a few degrees and its duration to ≤5 s, since the servos heat up.
  - Add a **kill key** in the server (space bar) that clears all effects and holds position. A second key turns off torque.

### 3.2 Vision (`server/vision.py`)
- **Table frame:** 4 ArUco markers taped at the corners of the play mat (IDs 0–3). Recompute the homography *every frame*, so a bumped tripod fixes itself.
- **Blocks:** ArUco 4×4 dictionary, IDs 10+, with the same ID on all faces. Map ID → color name in a config.
- **Camera:** lock exposure and focus (auto-exposure causes jitter). Use soft, even lighting. Mount the camera high enough to see the full reach of the arm plus the inventory tray.
- **Filtering:** smooth with an exponential moving average, add a ~0.5 cm deadband so platforms don't shiver under the player, and keep a missing marker's last pose for ~0.5 s before treating it as gone.
- **Debug window:** draw the markers, grid, block IDs, held state and FK tip dot. Put it on a second monitor during the demo, since judges like seeing the "robot's eyes."

### 3.3 World model: held, lifted and stacked blocks (`server/world.py`, `server/kinematics.py`)

> **Superseded, 2026-10-18.** This section describes frame-to-frame block tracking, which was
> built as `bridge/world.py` and then removed. Blocks are now read as cell labels by a vision
> model two seconds after the gripper opens, and nothing is tracked mid-carry. See
> `HANDOFF.md` and `bridge/README.md`. The rest of this section is kept as the record of why
> the tracking approach was tried.
An overhead camera can't see height, and the gripper covers the marker while holding a block. Solve both with **forward kinematics (FK)**:
- **FK:** the SO-101 is a base rotation plus a planar chain (shoulder_lift → elbow_flex → wrist_flex → tip). About 20 lines of numpy using link lengths from the SO-101 URDF (TheRobotStudio SO-ARM100 repo) or a ruler. Recent LeRobot versions may also include a kinematics helper; use it if yours has one.
- **Robot ↔ table calibration:** touch the gripper tip to 3–4 known points on the mat, then fit a 2D rotation + offset (plus a z offset). This takes about 5 minutes and is a script, `calibrate_robot_to_table.py`.
- **Held:** a block is held when its marker disappears close to the FK tip *and* the gripper is closed. A held block's position = FK tip position (this gives height for the crane lift).
- **Released:** when the gripper opens, the block becomes free again at the tip XY. Its **stack level** = how many tracked blocks are now hidden under that XY spot (occlusion memory), and z = level × block height.
- **Fallback if FK runs late:** apparent marker size as a rough height estimate, or limit crane-lift height to a few fixed levels.

### 3.4 Bridge (`server/ws_server.py` + Roblox `Bridge` module)
Python: `websockets` (or FastAPI with a WebSocket route and `/state` + `/event` for the fallback). Bind `0.0.0.0:8765`.

Roblox (server Script; enable **Game Settings → Security → Allow HTTP Requests**):
```lua
local HttpService = game:GetService("HttpService")
local ws = HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
    Url = "ws://localhost:8765",   -- or the robot laptop's LAN IP
})
ws.MessageReceived:Connect(function(msg)
    StateStore.update(HttpService:JSONDecode(msg))
end)
-- sending an event:
ws:Send(HttpService:JSONEncode({t = "event", name = "earthquake", intensity = 0.7, duration = 4}))
```
- **Fallback (published game):** expose the Python server through a tunnel (e.g., cloudflared), poll `GET /state` at about 5 Hz to stay under 500 requests/min, batch outgoing events, and rely on interpolation.
- **Mock mode** (`python -m server.main --mock`): fake arm as sine waves on each joint, fake blocks you drag with the mouse in the debug window. **Build this in hour 1** so Roblox work never waits on hardware.

### 3.5 Roblox
- **StateStore:** keeps the latest state, and everything else reads from it. Interpolates between packets on `Heartbeat`.
- **SkyArm:** a blocky rig first (Parts with link lengths matching the real arm, joined with Motor6Ds; set `Transform` from joint angles each frame). Fix sign and offset per joint by moving one real joint at a time. Real meshes (STL → OBJ/FBX through Blender) are a stretch goal.
- **BlockSync:** one platform per block ID. **Gotcha:** an anchored part moved by setting its CFrame does *not* carry a character standing on it reliably. Instead, use an **unanchored platform driven by AlignPosition + AlignOrientation** (high responsiveness, network owner = server). Cap platform speed so the player doesn't get flung. If riding is still unreliable, attach the player's root part to the platform with a constraint while the crane lift is moving. **Test this in hour 2–3; it is the biggest risk on the Roblox side.**
- **Collision for the 1v1 arm:** anchored, CFrame-driven parts don't fire `Touched` reliably. Check `workspace:GetPartsInPart()` against the arm links on the server every Heartbeat.
- **Modes:** `ObbyMode`, `ArenaMode`, `PatternMode`, plus `Events` (sends events to Python and runs the in-game visual effects).
- **Source control:** use Rojo if someone already knows it. Otherwise use one shared place file with Team Create and play-test locally.

---

## 4. Suggested repo layout
```
robo-obby/
  server/
    main.py               # starts robot thread, vision thread, ws server; --mock flag
    robot_loop.py
    effects.py
    kinematics.py
    vision.py
    world.py
    ws_server.py
    config.yaml           # ports, marker IDs→colors, block size, safe joint ranges
    calibrate_robot_to_table.py
    debug_view.py
  roblox/                 # Rojo project or .rbxl
    Bridge.lua  StateStore.lua  SkyArm.lua  BlockSync.lua
    modes/ObbyMode.lua  modes/ArenaMode.lua  modes/PatternMode.lua
    Events.lua
  assets/markers/         # printable ArUco sheets (corners + blocks)
  PROTOCOL.md
```

---

## 5. Team split (written for 3–4 people; with 2, merge A+B and C+D)

| Role | Owns |
|---|---|
| **A. Robot** | LeRobot setup and calibration, robot loop, effects, safety, FK, robot↔table calibration |
| **B. Vision** | Camera mount, markers, homography, block tracker, held/stack logic, debug view, mock mode |
| **C. Roblox core** | Bridge, StateStore, Sky Arm, BlockSync, moving-platform physics |
| **D. Roblox game** | Obby levels, events UI and visual effects, Arena, Pattern mode, then pitch, demo script and backup video |

---

## 6. Timeline (T = start; ~30 working hours plus sleep)

| Window | Goal | Milestone (demo-able) |
|---|---|---|
| **T+0–3: De-risk** | A: teleop working, custom loop reads joints. B: camera mounted, corner + block markers detected. C: Studio WebSocket ↔ Python "hello" both ways, *and* a test of a moving platform carrying a character. D: greybox the map, print the markers, buy/prep cubes | Each risky piece proven alone |
| **T+3–7: Live link** | Mock server → Roblox. Sky Arm mirrors the real arm. Blocks show up as platforms | **M1: real arm moves the Sky Arm** |
| **T+7–13: Obby core** | Levels 1–3, scale tuning, held/stack logic, crane lift | **M2: the crane lift carries a player over lava** |
| **T+13–16: Two-way** | Earthquake + 2 other effects, end to end, with safety caps | **M3: Roblox earthquake shakes the real arm** |
| *Sleep in shifts* | Keep one Roblox person and one hardware person awake at a time | |
| **T+16–21: 1v1 Arena** | Arena map, arm hitbox, grab, power-ups that trigger real effects | **M4: arena playable** |
| **T+21–25: Pattern Match** | Grid, target generator, matcher, timer and rounds | **M5: pattern mode playable** |
| **T+25–end: Freeze & polish** | Feature freeze ~6 h before judging. Bug fixes, sound, UI. **Record a backup demo video.** Rehearse the pitch 3× | **Demo ready** |

If behind schedule: cut Pattern Match first, then Arena power-ups. Never cut the Sky Arm, the crane lift or the earthquake.

---

## 7. Demo setup and script (~3 min)
**Physical layout:** robot + table + overhead cam in front. A large screen shows Roblox, facing both the audience *and* the arm operator (the operator needs to see the player to help them). A second screen shows the vision debug view. The Roblox player sits at the Studio laptop.

1. (20 s) Pitch: "What if a game character had a real-world teammate?" Move the leader and the Sky Arm moves.
2. (60 s) Obby: gap → stairs → **crane lift over lava**.
3. (30 s) Player presses "DON'T PRESS," an earthquake hits, and the real arm visibly shakes mid-carry.
4. (40 s) 1v1: the arm sweeps and grabs the player; the player freezes the real arm.
5. (20 s) Pattern Match teaser, plus architecture slide and close.

---

## 8. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Studio WebSocket to localhost/LAN fails | Test in hour 1; fall back to HTTP polling with interpolation |
| Platform doesn't carry the player / flings them | Constraint-driven platforms, speed cap, attach the player during lifts; test in hour 2–3 |
| Marker jitter makes platforms shiver | Locked exposure, larger markers, smoothing + deadband |
| Arm hides markers | FK-based held tracking; keep last pose briefly |
| Stack height wrong | Occlusion memory + FK at release; fallback to discrete levels |
| Shaking damages arm or drops blocks | Amplitude/duration caps, `max_relative_target`, kill key, don't shake during delicate lifts |
| LeRobot API differs from examples | Pin the version; check import paths on day one |
| Tripod bumped during demo | Per-frame homography from corner markers |
| Live demo dies | Backup video recorded by T+25 |

---

## 9. Still open (decide by T+3)
- **Blocks:** get the cubes now. Test the gripper's max opening before printing markers.
- **Roblox:** if anyone strongly wants a published game, decide by T+3, because it changes the bridge to polling and needs a tunnel.
- **Communication in Pattern Match:** voice only, or in-game text only (harder, which makes the Roblox player's role richer)?
- **Team size and roles:** assign the A–D owners above.

---

## 10. References
- Roblox `HttpService` / `CreateWebStreamClient` and `WebStreamClient`: https://create.roblox.com/docs/reference/engine/classes/WebStreamClient
- Roblox in-experience HTTP requests (limits): https://create.roblox.com/docs/cloud-services/http-service
- WebSockets in Studio announcement: https://devforum.roblox.com/t/websockets-support-in-studio-is-now-available/4021932
- LeRobot robot API (SO-100/SO-101 share `SOFollower`): https://huggingface.co/docs/lerobot/main/api/robots
- SO-101 teleop example (v0.6.1): https://raw.githubusercontent.com/huggingface/lerobot/v0.6.1/docs/source/il_robots.mdx
