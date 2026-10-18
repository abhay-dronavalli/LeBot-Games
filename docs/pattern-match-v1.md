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
- Roblox boards match the printed sheet, not a mirror image. Row A is the edge where the arm twin sits (+Z) and column 1 is on the tag 0 side (+X). Standing at the row C (tripod) side looking toward row A, A1 is far-left, A4 far-right, C1 near-left, C4 near-right, and the border numbers read 1 2 3 4 left to right. Standing at the arm side looking toward the tripod, tag 0 / A1 is on the right. This is rendering only (`Grid.worldPositionOf`); `Grid.cellOf` from table cm is unaffected.

## 2. Colors

`Config.colors = { "purple", "red", "yellow", "orange", "teal", "skyblue" }` with a `Color3` for each. Target generation only uses colors in this list. If vision can't separate orange/yellow or teal/skyblue at the venue, remove them from the list and nothing else changes.

## 3. Flow

```
Lobby -> enter Pattern cabinet -> MODE SELECT -> ROUND 1 -> INTERMISSION -> ROUND 2 -> INTERMISSION -> ROUND 3 -> RESULTS -> back to lobby
```

### Mode select
- Camera flies to a low front-left shot of the table inside the bedroom, the room blurred behind it (section 5, depth of field). ScreenGui with two black tiles: Easy and Hard, each with an image.
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

The cabinet stands in a teen gamer's bedroom. Two chunky wooden game boards sit on one wooden table, with matte foam blocks, warm window daylight and purple / blue LED accents.

- **Room** (`Workspace.Room`, built by `tools/build_room.lua`): four walls, ceiling, wood plank floor (top at Y = 1), a big rug under the table, one window on the -X wall with daylight coming in. Gamer props along the walls, clear of the table and the boards' spin sweep: a gaming desk with monitors and a chair, a bed, shelves, posters, lamps, a beanbag, a plant, and purple LED strips around the ceiling plus blue desk LEDs. All blocky parts, no scripts. The player spawns on a mat (`Room.Spawn.SpawnLocation`) just in front of the Entry pad. No Baseplate, no sky island.
- **Table** (`PatternCabinet.Table`, built by `tools/build_pattern_cabinet.lua`): Top plus four Legs, `#7a5638`, Wood material. Both boards sit on it.
- **Boards** (built by `tools/build_pattern_boards.lua`): each is one chunky raised wooden board (`Slab`, honey wood `#c28a52`, lighter than the table) with a raised, beveled border (`Frame`, `Bevel`, `BevelCorner`). The 12 cell tiles A1..C4 are inlaid wooden squares in two alternating tones, a chessboard: cherry `#9a643a` where row + column is even (A1), maple `#ead1a0` otherwise. They sit on a dark groove layer (`Base`, `#1c120b`, exactly the grid's size, the part `Grid.worldPositionOf` lays the cells out from), and the 0.2 stud gaps between tiles read as thin dark grooves. No labels inside the squares, no paper, no ink lines, no tags. Big burned-in row letters A, B, C are carved into both side borders (row A on the arm side, +Z) and column numbers 1-4 into the row C border (column 1 on the tag 0 side, +X), all readable from the row C side, where they read 1 2 3 4 left to right. Accents: TargetBoard gold `#d9a63a`, LiveBoard green `#3f9a58`, as an inlay line around the squares, a foot band, and the TARGET / LIVE word carved into the row A border (also on the slab's front face). The LiveBoard's slab runs on toward the player as an apron, and the arm twin stands on it.
- **Blocks** are rounded foam cubes 84% of a cell wide (the real 48 mm block on the 57 mm cell), very matte (SmoothPlastic): clones of the rounded-cube MeshPart `ReplicatedStorage.PatternMatch.BlockMesh` (Creator Store asset 6416975593, stored by the cabinet build tool; plain Parts if it is missing). Block colors are Apprentice's palette (section 8).
- **Arm twin** colors: off-white links `#e9e6df`, dark joints `#2a2d33`, SmoothPlastic.
- **Lighting** (`tools/setup_lighting.lua`): `LightingStyle = Realistic`, `GlobalShadows` on. A warm late-afternoon sun low in the west (-X) streams through the window onto the rug and the TargetBoard; indoor ambient is a touch cool; a warm SpotLight in the ceiling lamp keeps the table bright; mild Bloom makes the Neon LED strips glow.
- **Depth of field** (`StarterPlayerScripts.CabinetFocus`): drives `Lighting.CabinetFocus`, a DepthOfFieldEffect, every frame. FocusDistance is the camera's distance to a point just above the table's center, and InFocusRadius (24) keeps both boards and the arm sharp while the room behind blurs softly (FarIntensity 0.18). During the mode select shot (LocalPlayer attribute `PatternShot`) it eases to a stronger blur (radius 20, far 0.5, near 0.1).
- Two boards in the world, side by side, 3D parts, not GUI: TargetBoard and LiveBoard. Player walks around them freely.
- Only the TargetBoard spins: click anywhere on it to turn it 90 degrees around its vertical center axis, 0.3 s. The ClickDetector (`SpinClick`) sits on the whole TargetBoard Model, not just the base, because the tiles cover the base's top. Spins run on the server so everyone sees the same orientation, queue up, and wait while a tremor is on. The LiveBoard has no ClickDetector and `BoardSpinner` ignores requests for any board without one, so the LiveBoard and the arm twin always stay fixed, matching the real table. Board spacing is unchanged.
- Both boards draw blocks from the same pool (`PatternMatch.BlockPool`): one block part per cell and level (12 cells x `maxStackGlobal` levels, named `B2` and `B2_1`), made once, each sitting one block height above the one below, recolored or hidden, never created per tick.
- LiveBoard: 12 cell tiles plus a block at each cell and level with a counted block on the table, colored from `Config.colors`. Vanished cells use `Transparency = 1`: the inlaid square disappears and the dark groove layer under it shows as a hole. The white problem outline (extra, doubled, blocked) goes on the specific block part at fault; a block above the pool's top level is shown on the top part.
- TargetBoard: 12 wooden squares (never recolored) plus a tower of blocks, identical to the LiveBoard's, on each target cell in its target colors; non-target cells have no block. In hard mode the target blocks are outlined, and in the hidden phase every level turns mid gray (150, 150, 150, same blocks, recolored), which reads as gray on both wood tones. Intermission and Results show full colors.

## 6. Robot twin (v1, parts-built)

Lives in `ReplicatedStorage.ArmTwin` so every game can clone it. Six parts joined with Motor6D in the real joint order: `shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper`. A `TwinDriver` module reads `StateStore.arm` each Heartbeat and sets each Motor6D `Transform` from the angle, with per-joint sign and offset in `Config.twinJoints` so it can be tuned by moving one real joint at a time. Placed next to the LiveBoard so the arm appears to reach over the live grid.

Rest pose: `Config.twinRestPose` (real-arm degrees, gripper 0..100) is a folded SO-101 at rest, upper arm up and leaning back, forearm folded forward, hand hanging just in front of the base. The client shows it whenever there is no arm data (no sample yet, an empty one, or none for `Driver.STALE_SECONDS` = 1 s) and uses it for any joint a sample leaves out. The StateStore stand-in starts with no arm data and its fake arm moves in small waves around the rest pose.

## 7. Studio layout

```
Workspace.Room                              the bedroom: shell, window, lights, props, Spawn (SpawnLocation)
Workspace.PatternCabinet
  Entry (ProximityPrompt "Play Pattern Match"), Table (Top + Legs)
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
  CabinetFocus (LocalScript)               depth of field: keeps the table sharp, blurs the room
Lighting
  CabinetFocus (DepthOfFieldEffect), Bloom, Atmosphere, SunRays, Sky
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
  -- folded rest pose, shown while there is no arm data; same units as StateStore.arm, run through twinJoints
  twinRestPose = { shoulder_pan = 0, shoulder_lift = 125, elbow_flex = -128, wrist_flex = -76, wrist_roll = 0, gripper = 0 },
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
