# Pattern Match v1 spec

Roblox game for the SwampHacks project. Operator at the leader arm moves real blocks on a printed grid. Roblox player sees the target pattern and the live table, and calls out moves by voice. The operator never sees the Roblox screen.

Depends on the core only through `StateStore.blocks` (fields from plan.md: `id, color, x, y, level, held, visible, zone`) and `Events.fire(name, intensity, duration)`.

## 1. Grid

- 4 columns x 3 rows. Columns A-D run left to right as the operator sees them from the follower (white) arm. Rows 1-3 run from the arm toward the tripod. Row 1 is nearest the arm.
- All of this lives in `Config`, so size and origin can change without touching game code.
- Cell lookup: block `(x, y)` in cm -> `(col, row)` using `Config.gridOriginCm`, `Config.cellSizeCm`. A block counts as in a cell only if it sits inside the middle 70% of that cell. Anything else is "off grid" and ignored.
- `level` must be 0. Held blocks (`held == true`) are ignored.

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
- Target: `Config.blocksPerRound[round]` random cells (default 3, 4, 5), random colors from `Config.colors`. No two targets on the same cell. Colors can repeat.
- Round timer: `Config.roundSeconds[round]` (default 60, 75, 90).
- Target board shows the pattern. Live board shows the real table from `StateStore.blocks`, redrawn every 0.2 s.
- Clear condition: every target cell holds a block of the right color, no extra blocks on the grid, no block on a vanished cell. Must hold true for 1 s continuously (vision jitter).
- On clear: round score = seconds left. On timeout: round score 0, game continues to the next round.

### Easy vs Hard
| | Easy | Hard |
|---|---|---|
| Target colors | always shown | shown 5 s, hidden 5 s, repeating for the whole round |
| Hidden look | n/a | tiles go gray, outlines stay, so cells still show where blocks go |
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

- Two boards in the world, side by side, 3D parts, not GUI: TargetBoard and LiveBoard. Player walks around them freely.
- Click a board (ClickDetector on its base) to spin it 90 degrees. Tween, 0.3 s.
- LiveBoard: 12 cell parts plus one block part per visible block on the grid, colored from `Config.colors`. Vanished cells use `Transparency = 1`.
- TargetBoard: 12 cell parts, target cells colored, non-target cells neutral. In hard mode hidden phase, target cells turn gray.

## 6. Robot twin (v1, parts-built)

Lives in `ReplicatedStorage.ArmTwin` so every game can clone it. Six parts joined with Motor6D in the real joint order: `shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper`. A `TwinDriver` module reads `StateStore.arm` each Heartbeat and sets each Motor6D `Transform` from the angle, with per-joint sign and offset in `Config.twinJoints` so it can be tuned by moving one real joint at a time. Placed next to the LiveBoard so the arm appears to reach over the live grid.

## 7. Studio layout

```
Workspace.PatternCabinet
  Island, Entry (ProximityPrompt "Play Pattern Match")
  TargetBoard (Model): Base, Cells A1..D3
  LiveBoard (Model): Base, Cells A1..D3, Blocks (Folder)
  ArmTwin (clone)
  Sign (SurfaceGui): mode, round, timer, score, event banner
ReplicatedStorage
  PatternMatch.Config (ModuleScript)
  PatternMatch.Grid (ModuleScript)        cm -> cell, cell -> world position
  PatternMatch.Target (ModuleScript)      generate, compare
  ArmTwin (Model), TwinDriver (ModuleScript)
  Remotes: PatternUI (server -> client), PatternPick (client -> server)
ServerScriptService
  PatternMode (Script)                     state machine: ModeSelect, Round, Intermission, Results
  PatternEvents (ModuleScript)             scheduler + the event implementations
StarterGui
  PatternModeSelect (ScreenGui + LocalScript)
  PatternHud (ScreenGui + LocalScript)     timer, round, event banner
```

## 8. Config defaults

```lua
return {
  gridCols = 4, gridRows = 3,
  gridOriginCm = Vector2.new(0, 0),   -- set with core guy: A1 corner nearest the arm, in table cm
  cellSizeCm = 6,                      -- set after measuring the printed grid
  cellTolerance = 0.7,
  colors = { purple = Color3.fromRGB(128,0,255), red = Color3.fromRGB(255,0,0), yellow = Color3.fromRGB(255,220,0),
             orange = Color3.fromRGB(255,120,0), teal = Color3.fromRGB(0,160,160), skyblue = Color3.fromRGB(100,180,255) },
  blocksPerRound = { 3, 4, 5 },
  roundSeconds = { 60, 75, 90 },
  holdToClear = 1,
  intermissionSeconds = 10,
  modeSelectSeconds = 15,
  hard = { showSeconds = 5, hideSeconds = 5, eventEvery = 30 },
  easy = { eventEvery = 45 },
  vanishSeconds = 6, vanishCount = { 1, 2 },
  events = { "vanish", "tremor", "inverted" },
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
