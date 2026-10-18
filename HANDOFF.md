# Robo-Obby — handoff

Written 2026-10-17, updated 2026-10-18. Read this first after a restart, then `plan.md` and
`PROTOCOL.md`.

## What the job is

Map the SO-101 arm's movement and the physical block layout into Roblox, live. Python is the
WebSocket **server**; Roblox Studio connects out to it via `HttpService:CreateWebStreamClient`.
No middle server is needed, and there is a hard reason the server lives inside the arm process:
**only one process can hold COM7.**

## How the board works now (changed 2026-10-18)

Blocks are **not tracked**. A vision model (OpenAI, `gpt-4o` by default) is shown the overhead
frame and asked what is sitting in each printed cell. The read happens **two seconds after the
gripper opens** and otherwise not at all, because the board can only change when the arm lets
go. Between reads the same board is republished unchanged.

This replaced `bridge/world.py` (~700 lines of frame-to-frame tracking) and the bridge's use of
the segmentation pipeline. The thing all that machinery existed for — knowing where a block is
*while the arm carries it* — is not something the game needs. A block in the gripper is simply
still reported in the cell it was last read in, so no platform ever vanishes from under a
player, and it steps to its new cell at the next read. `held` is always false.

What this means in practice:

- **The AprilTags no longer matter to the bridge.** Nothing in `bridge/` fits a homography.
  The tags are still used by `robot/` for the arm's own calibration and autonomous mode, so do
  not peel them off — but a bad tag fit no longer breaks Roblox.
- **The printed cell labels now matter a lot.** The model reads `A1`…`C4` off the sheet.
  Use `robot/assets/grid_sheet_3x4.print.html`, printed and flat.
- **`OPENAI_API_KEY`** is in `.env` at the repo root (gitignored). `OPENAI_MODEL` overrides the
  model. A read is ~1,700 tokens and 2–4 s.
- **Credits are a single point of failure.** When the account empties the rig looks perfectly
  healthy and blocks just stop moving, so there is a red banner for it in both the viewer and
  Roblox (`roblox/BoardNotice.lua`), carrying the billing URL. See `notes.board` in
  `PROTOCOL.md`.

`robot/perception/` is untouched — `robot/executor.py` and every calibration script still
depend on the full segmentation pipeline. Only the bridge stopped using it.

## What is built and verified

- `bridge/` — the whole link. `board.py` is the core logic: the model call, the release
  trigger, cell → mm, and stable ids.
- `bridge/test_board.py` — 13/13 scenarios pass (parsing, ids, stacking, trigger, errors).
- `bridge/test_link.py` — 19/19 end-to-end checks pass.
- The live model call is verified against saved overhead frames: 3/3 cubes and 3/3 colours
  correct, ~3 s per read.
- `./run mock|follower|teleop|test|stop` — frees the port first; use this, not raw python.
- `robot/assets/grid_sheet_3x4.print.html` + `mat_tags.print.html` — printed, correct.

## Outstanding, in order

0. **Verify cell reading on the real labelled sheet.** The model has only been tested against
   saved frames of the *old, unlabelled* 3×3 sheet, where it had to guess cells from position.
   It got the cube count and every colour right, but cell accuracy is unproven. Take one frame
   of the current 3×4 labelled sheet with cubes in known cells and check it:
   `./run follower --vision` and compare the first read against the table.
1. **Verify stack detection.** Put one cube on another and check the read reports two cubes at
   levels 0 and 1 rather than one. This is the single hardest thing to see from overhead, and
   the prompt leans on side faces, shadows and relative size to get it. If it misses stacks,
   tighten `PROMPT` in `bridge/board.py` — it is prose, so it is cheap to iterate on.
2. **Studio.** `./run mock`, then the six files in `roblox/` (see `roblox/README.md`).
   `BoardNotice` is new; it needs to be added as a ModuleScript.
3. **Touch calibration** — quick, 4 corners, ~2 min:
   `~/lerobot/.venv/Scripts/python.exe -m robot.scripts.calibration.touch_calibrate`
   Still needed for the Sky Arm's pose (FK is published in the sheet frame), but **no longer
   needed for blocks** — those come from cell labels, which owe nothing to `sheet_to_base`.
   `auto_calibrate` can be skipped entirely for teleop.
4. `./run follower`, then `./run follower --vision`, then `./run teleop`.

## Known gaps

- **A cube moved by hand is not noticed until the next release.** The trigger is the gripper,
  so nothing fires if a human rearranges the board. `--board-poll S` adds a timed re-read as a
  safety net; it is off by default because each tick costs an API call.
- **Stacks deeper than 2 are clamped.** The arm cannot build higher and a cell is barely wider
  than a cube, so a taller answer is treated as a misread and the extra levels are dropped.
  `Board.clamped` reports it, and the viewer shows it as "over-tall".
- `--source auto` is unimplemented (raises SystemExit). Blocked on a naming conflict: the robot
  package uses letter=row, while `shared/config.py` and perception use letter=column — six of
  nine cells would be silently wrong. Note the bridge now uses letter=row throughout, matching
  the printed sheet.
- `robot/teleop_monitored.py` documents a servo-bus dropout 37-220 s into sustained motion.
- The old `GRIP_CLOSED_PCT` / `GRIP_EMPTY_PCT` guesswork is gone. The release trigger learns
  the jaw's range at runtime instead, so there is nothing to measure.

## Safety

Three layers: effect caps -> `max_relative_target` -> calibrated joint ranges. Space bar clears
all effects. The 12 V barrel jack is the hard stop.
