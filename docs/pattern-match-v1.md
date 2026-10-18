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
Lobby -> enter Pattern cabinet -> MODE SELECT -> SHIFT (tickets) -> RESULTS -> back to lobby
```

A Papa's-style ticket shift: one timer, target patterns arriving as tickets on a rail, made one at a time.

### Attract mode (Idle)
While the game is Idle (players in the room, before Play), `PatternMatch.Attract` runs a demo loop on the boards, driven by the server so everyone sees the same thing:
- The TargetBoard shows a pattern (`Target.generate`, 2-4 blocks). The LiveBoard places the matching blocks one at a time, `Config.attractPlaceInterval` (0.7 s) apart, each dropping in with a short ease; all bottom blocks first, then the stacked ones on top of them.
- Matched: a short pause, then the celebration (below) with "COMPLETE!", the blocks on both boards swell and shrink away, a short gap, then the next pattern.
- `Config.attractPatterns` (5) patterns per set, at least one with a stack, then a fresh set, forever.
- A floating sign above the boards (`PatternCabinet.AttractSign`, a BillboardGui) reads "Match the target board!" / "Press Play to start".
- No arm data goes to the clients while it runs, so the arm twin rests in its folded pose.
- It writes only to the two boards' renderers, its own sign and the celebration. It never touches `Core.StateStore` or anything the game reads, and the LiveBoard is not drawn from StateStore while it runs.
- The moment mode select (or a forced mode) starts, it stops at once: no timers or animations left, both boards cleared, every block back at its rest place, sign and sparkles off. The normal game then draws the boards. It starts again whenever the game returns to Idle (after Results). `Config.attractEnabled = false` turns it off.

### Mode select
- Camera flies to a low front-left shot of the table inside the bedroom, the room blurred behind it (section 5, depth of field). ScreenGui with two black tiles: Easy and Hard, each with an image.
- 15 s countdown; no pick = Easy.
- Back button to the lobby: later, not v1.

### Shift
- One timer counting down from `Config.shiftSeconds` (default 180).
- **Tickets.** The first ticket arrives at shift start. After that a new ticket arrives every random `Config.ticketIntervalMin..Max` seconds (default 12-20). The rail holds at most `Config.ticketRailMax` (4); while it is full the arrival timer pauses. Tickets are numbered from #1 each shift.
- **A ticket is a target pattern**: `Config.ticketBlocksMin..Max` blocks in total (default 2-4), random colors from `Config.colors` (they can repeat, within a tower too), in towers up to `Config.maxStackGlobal` (2) high. A target cell is a list of colors bottom to top, e.g. `B2 = {"red", "teal"}`. `Target.generate(n, maxHeight, rng, stackChance)` places blocks one at a time: after the first, each block goes on top of a tower that still has room with probability `stackChance`, otherwise on a fresh cell. The stack chance ramps linearly over the shift from `Config.stackChanceStart` (0.2) to `Config.stackChanceEnd` (0.6).
- **Active ticket.** The oldest ticket is active by default; any player can click a ticket card to make it active instead (`TicketPick` remote). The TargetBoard shows the active ticket. The Live board shows the real table from `StateStore.blocks`, redrawn every 0.2 s.
- **Compare** runs per cell, per level against the active ticket: `missing` (a target level with no block), `wrong` (wrong color at that level, including a tower built in the wrong order), `extra` (a block at a level the target doesn't have, on a non-target cell, or at or above `maxStackGlobal`), `doubled` (2+ blocks at one cell and level), `blocked` (any block on a vanished cell).
- **Completing.** When every tower of the active ticket matches exactly bottom to top, nothing else is on the grid and no block sits on a vanished cell, for `Config.holdToClear` (1 s) continuously: ORDER UP. The ticket's points are added, `Config.ticketTimeBonus` (3) seconds go on the shift timer, the ticket leaves the rail and the oldest remaining ticket becomes active. If the rail is empty, the next ticket arrives right away.
- No intermission and no clear-the-grid step: blocks stay on the table and get reused for the next ticket.
- The shift ends when the timer hits 0.

### Scoring
- Each completed ticket = `Config.ticketPoints`: 1 point + 1 per flat block (level 0) + 3 per stacked block (level 1). Example: 2 flat + 1 stacked on top = 1 + 2 + 3 = 6.
- Each ticket card shows its point value.

### Celebration (COMPLETE! and ORDER UP)
`PatternMatch.Celebrate`, one shared effect for the attract demo's "COMPLETE!" and the shift's "ORDER UP! +points", so they feel the same. Server-driven, so everyone sees it:
- A big sparkle burst rising off both boards for about 1.5 s: a `CelebrateSparkle` ParticleEmitter in each board's Base, rate 450, particles up to 1.8 studs, living up to 1.6 s.
- A quick white flash on every cell of both boards; the squares then ease back to their wood colors.
- Big text above the boards (`PatternCabinet.CelebrateText`, a BillboardGui, placed a little toward the TargetBoard so the arm twin doesn't cut through it) that pops in with a scale tween and stays up for 1.5 s, plus a pop sound.
- Mode select (or any state change that stops the demo) cuts a celebration short and restores the cell colors at once.

### Ticket rail HUD (`StarterGui.PatternHud`)
- Bottom left, Papa's-style: paper ticket cards standing on a rail along the bottom edge, oldest on the left. This keeps them clear of the top-left Roblox chat and buttons, the top-right status panel and the ORDER UP text. On mobile the rail shares the bottom-left corner with the thumbstick. Each card shows a mini 4 x 3 grid of the pattern (row A on top, columns 1-4 left to right, like the board seen from the row C side; a stacked cell is split, top color over bottom color, with a small "2" badge), its point value and its age.
- The active ticket is raised with an orange border and "ACTIVE". Clicking a card makes it active.
- New tickets slide in; a completed ticket gets an "ORDER UP! +points" stamp and flies up and off the screen. The big "ORDER UP! +points" is the 3D celebration above the boards, so the HUD doesn't repeat it.
- Status panel (top right): mode, shift timer (flashes "+3s" on an ORDER UP), score, tickets completed, the Hard reveal phase, the event banner and the game message.

### Easy vs Hard
| | Easy | Hard |
|---|---|---|
| Target colors | always shown | shown 5 s, hidden 5 s, repeating for the whole shift, on the TargetBoard and the ticket cards |
| Hidden look | n/a | every target block, at every level, goes gray, outlines stay; the cards gray their squares but keep the layout, so the player still sees where blocks go and how tall each tower is |
| Event interval | every 45 s | every 30 s |

### Results
Shown when the shift ends, for `Config.resultsSeconds`: tickets completed, total points, and one line per completed ticket (number, blocks, stacked or not, points, seconds it took). Then back to Idle. Leaderboard entry (DataStore keyed by UserId) later, not v1.

## 4. Events

An event fires on the interval above, picked at random from the enabled list. One event at a time. Events only run during the shift (never in mode select or results). Vanish picks cells that are empty and not in the ACTIVE ticket's pattern.

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
- TargetBoard: 12 wooden squares (never recolored) plus a tower of blocks, identical to the LiveBoard's, on each target cell in its target colors; non-target cells have no block. In hard mode the target blocks are outlined, and in the hidden phase every level turns mid gray (150, 150, 150, same blocks, recolored), which reads as gray on both wood tones. Outside the shift the TargetBoard is empty.

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
ReplicatedStorage
  PatternMatch.Config (ModuleScript)
  PatternMatch.Grid (ModuleScript)        cm -> cell, cell -> world position
  PatternMatch.Target (ModuleScript)      generate, compare
  PatternMatch.LiveBoard (ModuleScript)   pooled block parts on the LiveBoard
  PatternMatch.Game (ModuleScript)        state machine: Idle, ModeSelect, Shift (tickets), Results
  PatternMatch.Attract (ModuleScript)     the Idle demo loop on the boards
  PatternMatch.Celebrate (ModuleScript)   the shared COMPLETE! / ORDER UP celebration
  PatternMatch.PatternEvents (ModuleScript) event scheduler + vanish / tremor / inverted
  PatternMatch.TargetBoard (ModuleScript) target colors, Hard-mode hidden look
  PatternMatch.Remotes: PatternState (BindableEvent, server-only state changes)
  ArmTwin (Model, parts-built SO-101) with Rig (geometry, FK, builder) and Driver (server broadcast,
    client easing + Motor6D Transforms) ModuleScripts; the LiveBoard holds a clone without the modules
  PatternMatch.Remotes: ArmPose (UnreliableRemoteEvent, arm angles 20 Hz, server -> clients)
  Remotes: PatternUI (server -> client), PatternPick (chooser -> server: mode), TicketPick (any player -> server: active ticket)
ServerScriptService
  PatternMode (Script)                     wires the prompt and remotes to PatternMatch.Game
StarterPlayer.StarterPlayerScripts
  ArmTwinClient (LocalScript)              eases the LiveBoard's arm twin toward ArmPose samples
  CabinetFocus (LocalScript)               depth of field: keeps the table sharp, blurs the room
Lighting
  CabinetFocus (DepthOfFieldEffect), Bloom, Atmosphere, SunRays, Sky
StarterGui
  PatternModeSelect (ScreenGui + LocalScript)
  PatternHud (ScreenGui + LocalScript)     ticket rail, shift timer, score, event banner, results
```

## 8. Config defaults

```lua
return {
  useFakeState = true,                 -- Core.StateStore stand-in (fake arm, Debug hook, debugAutoSolve); set false once the real core is in
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
  -- The shift: one countdown; tickets (target patterns) arrive on a rail and are made one at a time.
  shiftSeconds = 180,
  ticketIntervalMin = 12, ticketIntervalMax = 20, -- seconds between ticket arrivals (random in this range)
  ticketRailMax = 4,                   -- tickets the rail holds; the arrival timer pauses while it is full
  ticketBlocksMin = 2, ticketBlocksMax = 4, -- blocks per ticket, towers included (towers up to maxStackGlobal)
  stackChanceStart = 0.2,              -- chance a ticket block goes on top of another, ramping linearly over
  stackChanceEnd = 0.6,                --   the shift from start to end
  ticketTimeBonus = 3,                 -- seconds added to the shift timer per completed ticket
  ticketPoints = { ticket = 1, flat = 1, stacked = 3 }, -- per ticket, per level 0 block, per level 1 block
  holdToClear = 1,
  attractEnabled = true,               -- Idle: demo loop on the boards (PatternMatch.Attract)
  attractPlaceInterval = 0.7,          -- seconds between the demo's block placements
  attractPatterns = 5,                 -- demo patterns per set before a fresh set is generated
  modeSelectSeconds = 15,
  modeConfirmSeconds = 1.5,            -- "HARD MODE" confirmation before the shift
  resultsSeconds = 10,                 -- how long Results stays up before Idle
  debugAutoSolve = false,              -- testing: fake StateStore rebuilds the board for the active ticket 3 s after it becomes active,
                                       -- reusing the blocks already there (leftovers go to the tray)
  debugFastTimers = false,             -- testing: every game timer (shift, ticket arrivals, events, reveal) runs 4x faster
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
