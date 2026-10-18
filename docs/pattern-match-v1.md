# Pattern Match v1 spec

Roblox game for the SwampHacks project. Operator at the leader arm moves real blocks on a printed grid. Roblox player sees the target pattern and the live table, and calls out moves by voice. The operator never sees the Roblox screen.

Depends on the core only through `StateStore.blocks` (fields from plan.md: `id, color, x, y, z, yaw, level, held, visible, zone`) and `Events.fire(name, intensity, duration)`.

## 1. Grid

- Matches the printed grid sheet: 3 rows x 4 columns. Rows are letters A-C: row A is on the arm side (nearest tags 0 and 1), row C toward the tripod. Columns are numbers 1-4: column 1 nearest tag 0, column 4 nearest tag 1. Cells are named letter + number, "A1".."C4".
- Table frame (plan.md): cm, x from tag 0 toward tag 1 (along the columns), y from tag 0 toward tag 3 (along the rows), z up. Cell A1's outer corner is at `Config.gridOriginCm` = (2.540, 2.223); cells are `Config.cellSizeCm` = 5.715 cm square.
- All of this lives in `Config`, so size and origin can change without touching game code.
- Cell lookup: block `(x, y)` in cm -> `(row, col)` using `Config.gridOriginCm`, `Config.cellSizeCm`. A block counts as in a cell only if it sits inside the middle 70% of that cell. Anything else is "off grid" and ignored.
- `Config.flipX = true` mirrors columns (1 <-> 4) and `Config.flipY = true` mirrors rows (A <-> C) in the cell lookup, in case the sheet or the tags turn out reversed at the venue. Both default to false. The boards don't change.
- Held blocks (`held == true`) are ignored. Blocks in an ignored zone (`Config.ignoreZones`, default the tray) are ignored. `visible == false` blocks still count (the core keeps tracking a hidden marker at its last pose).
- Stacks: a cell holds a tower, read from each block's `level` field (0 = on the table, 1 = on top of a level 0 block). `Grid.liveGridFrom` builds every cell as a list indexed by level, `{ [0] = {"red"}, [1] = {"teal"} }`. The core owns stack logic, so a block is placed at the level it reports: a level 1 block with nothing under it still sits at level 1. Towers are at most `Config.maxStackGlobal` = 2 high; any block at a level at or above that always counts as extra.
- Doubles rule: if 2+ counted blocks land in the same cell at the same level, that level can never count as correct. `Target.compare` reports the cell in a `doubled` list and returns `clear = false`.
- Roblox boards: row A is the edge where the arm twin sits, and column 1 is on the same side as tag 0. Seen from the row A edge, a board is the table as the operator sees it, not a mirror image.

## 2. Colors

`Config.colors = { "purple", "red", "yellow", "orange", "teal", "skyblue" }` with a `Color3` for each. Target generation only uses colors in this list. If vision can't separate orange/yellow or teal/skyblue at the venue, remove them from the list and nothing else changes.

## 3. Flow

```
Lobby -> enter Pattern cabinet -> MODE SELECT -> ROUND 1 -> INTERMISSION -> ROUND 2 -> INTERMISSION -> ROUND 3 -> RESULTS -> back to lobby
```

### Mode select
- Camera moves to hover over the island, blue sky behind. ScreenGui with two black tiles: Easy and Hard, each with an image.
- 15 s countdown; no pick = Easy.
- Back button to the lobby: later, not v1.

### Round
- Target: `Config.blocksPerRound[round]` blocks in total (default 3, 4, 5), random colors from `Config.colors`, arranged in towers no taller than `Config.maxStackByRound[round]` (default 1, 2, 2: round 1 is flat, rounds 2 and 3 may stack 2 high). A target cell is a list of colors bottom to top, e.g. `B2 = {"red", "teal"}`. `Target.generate(n, maxHeight)` places blocks one at a time: after the first, each block goes on top of a target tower that still has room with probability `Config.stackChance` (default 0.5), otherwise on a fresh cell, so at most 12 cells are used. Colors can repeat, within a tower too.
- Round timer: `Config.roundSeconds[round]` (default 60, 75, 90).
- Target board shows the pattern. Live board shows the real table from `StateStore.blocks`, redrawn every 0.2 s.
- Compare runs per cell, per level: `missing` (a target level with no block), `wrong` (wrong color at that level, including a tower built in the wrong order), `extra` (a block at a level the target doesn't have, on a non-target cell, or at or above `maxStackGlobal`), `doubled` (2+ blocks at one cell and level), `blocked` (any block on a vanished cell).
- Clear condition: every target tower matches exactly bottom to top, nothing else on the grid, no block on a vanished cell. Must hold true for 1 s continuously (vision jitter).
- On clear: round score = seconds left. On timeout: round score 0, game continues to the next round.

### Easy vs Hard
| | Easy | Hard |
|---|---|---|
| Target colors | always shown | shown 5 s, hidden 5 s, repeating for the whole round |
| Hidden look | n/a | every target block, at every level, goes gray; outlines stay, so the player still sees where blocks go and how tall each tower is |
| Event interval | every 45 s | every 30 s |

### Intermission (after every round)
- 10 s countdown. Big text: "Clear the grid. Swap seats if you want."
- Next round starts when the 10 s is up AND the grid reads empty. If the grid still has blocks after 10 s, the message changes to "Waiting for grid to clear" and the next round starts the moment it's empty.

### Results
Total score, per-round breakdown, leaderboard entry (DataStore keyed by UserId, v1 can be in-memory).

## 4. Events

An event fires on the interval above, picked at random from the enabled list. One event at a time. Events never fire during intermission or mode select.

| Event | Roblox side | Real arm side (via `Events.fire`) | v1 |
|---|---|---|---|
| Vanishing Tile | 1 to 2 random EMPTY target cells (cells with no block needed and no block on them) turn invisible on the Live board for `Config.vanishSeconds` (default 6). If a block lands on a vanished cell, the cell stays vanished and progress is blocked until that block is removed. No pause, no penalty beyond lost time. | none | yes |
| Tremor | Live board and camera shake for the duration | `earthquake`, intensity 0.5, duration 4 | yes |
| Inverted | banner "ARM INVERTED" | `mirror`, duration 8. Ask core to invert shoulder pan only and lower the speed cap while active | yes if core has it, else skip |
| Fog | banner "ARM LAGGING" | `fog`, duration 8 | later |

Each event shows a 2 s warning banner before it starts, so the player can call it out. The operator is blind to the screen, so the callout is the whole point.

## 5. Boards

Styled after the Apprentice 3D view (github.com/NSang22/apprentice, `ui/view3d.js`): warm wood, a printed paper sheet, matte foam blocks, warm key light with a cool fill.

- One wooden table (`PatternCabinet.Table`: Top plus four Legs, `#7a5638`, Wood material) that both boards sit on. Each board is a thin wooden slab (`Slab`, a shade darker, `#5f4129`) with a paper sheet on top (`Paper`, off-white `#f7f6f2`, SmoothPlastic) that runs 0.8 studs past the grid on every side. On the paper sits the black ink layer (`Base`, `#111`, exactly the grid's size) and on that the 12 paper-colored cell tiles with 0.2 stud gaps, so the gaps draw the thick grid lines. `Base` stays the part `Grid.worldPositionOf` lays the cells out from. Cell labels (A1..C4) are small gray (`#555`) text in each cell's top-left corner, upright for someone standing on the row C side; "ARM SIDE" in light gray sits in the row A margin. Four black-and-white AprilTag-style squares (`Tag`) sit at the paper's corners, decorative. "TARGET" / "LIVE" are dark text on the slab's row A edge. The LiveBoard's slab runs on toward the player as an apron, and the arm twin stands on it.
- Blocks are rounded foam cubes 84% of a cell wide (the real 48 mm block on the 57 mm cell), very matte (SmoothPlastic): clones of the rounded-cube MeshPart `ReplicatedStorage.PatternMatch.BlockMesh` (Creator Store asset 6416975593, stored by the build tool; plain Parts if it is missing). Block colors are Apprentice's palette (section 8).
- Arm twin colors: off-white links `#e9e6df`, dark joints `#2a2d33`, SmoothPlastic.
- Lighting (set by the build tool): mid-afternoon sun from the player's front-left as the warm key (`ColorShift_Top` warm), slightly cool `Ambient` / `OutdoorAmbient`, `ShadowSoftness` 0.6. `Lighting.Technology = Future` must be set by hand in the Properties panel (scripts can't), so blocks cast soft shadows on the paper.
- Two boards in the world, side by side, 3D parts, not GUI: TargetBoard and LiveBoard. Player walks around them freely.
- Click anywhere on a board to spin it 90 degrees around its vertical center axis, 0.3 s. The ClickDetector (`SpinClick`) sits on the whole board Model, not just the base, because the tiles cover the base's top. Spins run on the server so everyone sees the same orientation, queue up, and wait while a tremor is on.
- Both boards draw blocks from the same pool (`PatternMatch.BlockPool`): one block part per cell and level (12 cells x `maxStackGlobal` levels, named `B2` and `B2_1`), made once, each sitting one block height above the one below, recolored or hidden, never created per tick.
- LiveBoard: 12 cell tiles plus a block at each cell and level with a counted block on the table, colored from `Config.colors`. Vanished cells use `Transparency = 1`, which shows the ink layer as a black hole in the paper. The white problem outline (extra, doubled, blocked) goes on the specific block part at fault; a block above the pool's top level is shown on the top part.
- TargetBoard: 12 paper-colored cell tiles plus a tower of blocks, identical to the LiveBoard's, on each target cell in its target colors; non-target cells have no block. In hard mode the target blocks are outlined, and in the hidden phase every level turns light gray (`#b0b0b0`, same blocks, recolored). Intermission and Results show full colors.

## 6. Robot twin (v1, parts-built)

Lives in `ReplicatedStorage.ArmTwin` so every game can clone it. Six parts joined with Motor6D in the real joint order: `shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper`. A `TwinDriver` module reads `StateStore.arm` each Heartbeat and sets each Motor6D `Transform` from the angle, with per-joint sign and offset in `Config.twinJoints` so it can be tuned by moving one real joint at a time. Placed next to the LiveBoard so the arm appears to reach over the live grid.

## 7. Studio layout

```
Workspace.PatternCabinet
  Island, Entry (ProximityPrompt "Play Pattern Match")
  TargetBoard (Model): Base, Cells A1..C4
  LiveBoard (Model): Base, Cells A1..C4, Blocks (Folder)
  ArmTwin (clone)
  Sign (SurfaceGui): mode, round, timer, score, event banner
ReplicatedStorage
  PatternMatch.Config (ModuleScript)
  PatternMatch.Grid (ModuleScript)        cm -> cell, cell -> world position
  PatternMatch.Target (ModuleScript)      generate, compare
  PatternMatch.LiveBoard (ModuleScript)   pooled block parts on the LiveBoard
  PatternMatch.Game (ModuleScript)        state machine: Idle, ModeSelect, Round, Intermission, Results
  PatternMatch.PatternEvents (ModuleScript) event scheduler + vanish / tremor / inverted
  PatternMatch.TargetBoard (ModuleScript) target colors, Hard-mode hidden look
  PatternMatch.Remotes: PatternState (BindableEvent, server-only state changes)
  ArmTwin (Model, parts-built SO-101) with Rig (geometry, FK, builder) and Driver (server broadcast,
    client easing + Motor6D Transforms) ModuleScripts; the LiveBoard holds a clone without the modules
  PatternMatch.Remotes: ArmPose (UnreliableRemoteEvent, arm angles 20 Hz, server -> clients)
  Remotes: PatternUI (server -> client), PatternPick (client -> server)
ServerScriptService
  PatternMode (Script)                     wires the prompt and remotes to PatternMatch.Game
StarterPlayer.StarterPlayerScripts
  ArmTwinClient (LocalScript)              eases the LiveBoard's arm twin toward ArmPose samples
StarterGui
  PatternModeSelect (ScreenGui + LocalScript)
  PatternHud (ScreenGui + LocalScript)     timer, round, event banner
```

## 8. Config defaults

```lua
return {
  useFakeState = true,                 -- Core.StateStore stand-in invents blocks; set false once the real core is in
  gridCols = 4, gridRows = 3,          -- printed sheet: columns 1-4 (tag 0 -> tag 1), rows A-C (arm -> tripod)
  gridOriginCm = Vector2.new(2.540, 2.223), -- table cm of cell A1's outer corner (the corner nearest tag 0)
  cellSizeCm = 5.715,                  -- measured on the printed sheet
  flipX = false,                       -- true mirrors columns (1 <-> 4) if the sheet or tags turn out reversed
  flipY = false,                       -- true mirrors rows (A <-> C)
  cellTolerance = 0.7,                 -- a block counts only inside the middle 70% of a cell
  maxStackGlobal = 2,                  -- hard cap on tower height; a block at level >= this always counts as extra
  ignoreZones = { tray = true },       -- block zones that never count (plan.md: the inventory tray maps to nothing)
  boardCellStuds = 4,                  -- studs per grid cell on the boards; with cellSizeCm this is the cm -> stud scale
  twinBaseOffsetCm = 9,                -- arm twin base center, measured from the grid's row A edge toward the operator
  -- SO-101 link lengths in cm: joint-to-joint distances from TheRobotStudio's so101_new_calib.urdf
  twinLinksCm = { baseHeight = 6.2, shoulderHeight = 5.4, upperArm = 11.6, forearm = 13.5, wrist = 6.4,
                  jawHinge = 3.6, gripper = 9.8 },
  -- Target generation only uses colors listed here. Remove an entry if vision can't separate it.
  -- Values are the Apprentice 3D view's block palette.
  colors = { red = Color3.fromHex("e2383f"), orange = Color3.fromHex("f5862a"), yellow = Color3.fromHex("f6c933"),
             teal = Color3.fromHex("16a59b"), skyblue = Color3.fromHex("62bdea"), purple = Color3.fromHex("8a5cc7") },
  blocksPerRound = { 3, 4, 5 },        -- total blocks per round, towers included
  maxStackByRound = { 1, 2, 2 },       -- tallest tower a round's target may ask for (clamped to maxStackGlobal)
  stackChance = 0.5,                   -- chance a generated block goes on top of an existing target block
                                       -- instead of a new cell, when the round's height allows
  roundSeconds = { 60, 75, 90 },
  holdToClear = 1,
  intermissionSeconds = 10,
  modeSelectSeconds = 15,
  modeConfirmSeconds = 1.5,            -- "HARD MODE" confirmation before round 1
  resultsSeconds = 10,                 -- how long Results stays up before Idle
  debugAutoSolve = false,              -- testing: fake StateStore solves each round after 5 s, clears the grid 3 s into intermission
  debugFastTimers = false,             -- testing: every game timer runs 4x faster
  debugForceMode = nil,                -- testing: "easy" or "hard" makes ModeSelect pick that mode; nil picks Easy
  debugEventEvery = nil,               -- testing: seconds between events in both modes, instead of easy/hard.eventEvery
  hard = { showSeconds = 5, hideSeconds = 5, eventEvery = 30 },
  easy = { eventEvery = 45 },
  vanishSeconds = 6, vanishCount = { 1, 2 },
  events = { "vanish", "tremor", "inverted" }, -- tremor and inverted durations (4 s, 8 s) live in PatternEvents
  twinJoints = { shoulder_pan = {sign=1, offset=0}, shoulder_lift = {sign=1, offset=0}, elbow_flex = {sign=1, offset=0},
                 wrist_flex = {sign=1, offset=0}, wrist_roll = {sign=1, offset=0}, gripper = {sign=1, offset=0} },
}
```

## 9. Build order for the execution session

1. Config, Grid, Target modules with unit-style tests run through `execute_luau` (cm -> cell edge cases, compare with extra block, compare with vanished cell).
2. LiveBoard renderer from `StateStore.blocks`, driven by the core's mock mode.
3. PatternMode state machine with Easy only, no events: mode select stub that auto-picks Easy, rounds, intermission, results.
4. Hard mode show/hide cycle.
5. Events: vanish first (Roblox-only), then tremor, then inverted.
6. Mode select screen with camera hover, tiles, countdown.
7. Click-to-spin boards.
8. ArmTwin parts model + TwinDriver, tune signs against the real arm.
9. Sign and HUD polish.

## 10. Agree with the core guy

- `gridOriginCm` and `cellSizeCm` for the printed 4x3 grid.
- Which of `earthquake`, `mirror`, `fog` exist in `effects.apply()`, and that `mirror` inverts shoulder pan only with a lower speed cap.
- Camera exposure locked at the venue, and a color test for all six blocks before targets use them.
