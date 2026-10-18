# Robo-Obby — handoff

Written 2026-10-17. Read this first after a restart, then `plan.md` and `PROTOCOL.md`.

## What the job is

Map the SO-101 arm's movement and the physical block layout into Roblox, live. Python is the
WebSocket **server**; Roblox Studio connects out to it via `HttpService:CreateWebStreamClient`.
No middle server is needed, and there is a hard reason the server lives inside the arm process:
**only one process can hold COM7.**

## What is built and verified

- `bridge/` — the whole link. `world.py` is the core new logic: stable block identity
  (nearest-neighbour association + `settled_at` for stack order) and height, neither of which
  `robot/perception/scene.py` provided.
- `bridge/test_world.py` — 5/5 tracker scenarios pass.
- `bridge/test_link.py` — 14/14 end-to-end checks pass (verified three runs in a row).
- 402/402 coordinate conversions match between `viewer/` and `roblox/Mapping.lua`.
- `./run mock|follower|teleop|test|stop` — frees the port first; use this, not raw python.
- `robot/assets/grid_sheet_3x4.print.html` + `mat_tags.print.html` — printed, correct.
- All 3x3 hardcoding removed (`touch_calibrate`, `auto_calibrate`, `color_calibrate`,
  `config._sheet_size`). The grid is 3 rows x 4 cols, read from `robot/assets/workspace_sheet.json`.

## Outstanding, in order

0. **Re-tape the tags.** Currently rotated 180 deg and ~70 mm too far out (fit error 4.36 mm).
   Swap the diagonals (0<->2, 1<->3) so ids run 0,1,2,3 clockwise from the top-left, and slide
   each tag in until its inner corner touches the sheet corner. Then:
   `~/lerobot/.venv/Scripts/python.exe -m robot.scripts.tests.scene_snapshot`
   Expect 4 tags and fit error under ~1.5 mm. Put blocks on the grid, not the wood.
1. **Studio.** `./run mock`, then the five files in `roblox/` (see `roblox/README.md`).
2. **Touch calibration** — quick, 4 corners, ~2 min:
   `~/lerobot/.venv/Scripts/python.exe -m robot.scripts.calibration.touch_calibrate`
   Needed even for pure teleop: `world.py` compares the FK tip (arm base frame) against camera
   block positions (sheet frame), so `sheet_to_base` must be right or held-block detection and
   the crane lift break. `auto_calibrate` can be skipped entirely for teleop.
3. `./run follower`, then `./run follower --vision`, then `./run teleop`.

## Known gaps

- `GRIP_CLOSED_PCT = 35.0` / `GRIP_EMPTY_PCT = 8.0` in `bridge/world.py` are inferred from
  `robot/skills.py`, **not measured**. Held-block detection depends on them.
- `--source auto` is unimplemented (raises SystemExit). Blocked on a naming conflict: the robot
  package uses letter=row, while `shared/config.py` and perception use letter=column — six of
  nine cells would be silently wrong.
- `robot/teleop_monitored.py` documents a servo-bus dropout 37-220 s into sustained motion.

## Safety

Three layers: effect caps -> `max_relative_target` -> calibrated joint ranges. Space bar clears
all effects. The 12 V barrel jack is the hard stop.
