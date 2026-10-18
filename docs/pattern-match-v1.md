# Pattern Match v1 spec

Roblox game for the SwampHacks project. Operator at the leader arm moves real blocks on a printed grid. Roblox player sees the target pattern and the live table, and calls out moves by voice. The operator never sees the board: in Roblox they are the **robot** role, whose screen shows the timer and the score and nothing of the target (section 12, docs/roles.md).

Depends on the core only through `Core.StateStore` (blocks and arm points from the core's `Bridge`, PROTOCOL.md), `Core.Events.fire(name, intensity, duration)`, and `Core.Roles` / `Core.GameRegistry` (who is the player, who is the robot, which game is active). See section 11 for the bridge and section 12 for roles.

## 1. Grid

- Matches the printed grid sheet: 3 rows x 4 columns. Rows are letters A-C: row A is on the arm side (nearest tags 0 and 1), row C toward the tripod. Columns are numbers 1-4: column 1 nearest tag 0, column 4 nearest tag 1. Cells are named letter + number, "A1".."C4".
- Sheet frame (PROTOCOL.md): **mm**, origin at the grid sheet's top-left corner, x from tag 0 toward tag 1 (along the columns), y down the page from tag 0 toward tag 3 (along the rows, away from the arm), z up off the paper.
- The grid comes from the bridge: the hello frame's `space.grid` (`origin_mm`, `cell_mm`, `rows`, `cols`) goes to `Grid.setGeometry` on the server. Until a hello arrives (and in fake mode) `Config` is the fallback: cell A1's outer corner at `Config.gridOriginMm` = (25.4, 22.225), cells `Config.cellSizeMm` = 57.15 mm square, `Config.gridRows` x `gridCols` = 3 x 4. The boards are built with Config's 3 x 4 cells, so a hello with a different row or column count keeps 3 x 4 (with a warning); its origin and cell size still apply.
- Cell lookup: block `(x, y)` in mm -> `(row, col)` using `Grid.geometry()`. A block anywhere inside a cell counts for that cell (`Config.cellTolerance` = 1.0, like the obby; a point exactly on a shared edge belongs to the higher row / column). Anything outside the 3 x 4 grid is "off grid" and ignored.
- `Config.flipX = true` mirrors columns (1 <-> 4) and `Config.flipY = true` mirrors rows (A <-> C) in the cell lookup, in case the sheet or the tags turn out reversed at the venue. Both default to false. The boards don't change.
- Held blocks (`held == true`) are ignored. A block with `visible == false` (the camera can't see it right now, usually because the arm is over it; the core keeps it at its last pose) still counts until its `age` (seconds since last seen) passes `Config.staleBlockSeconds` = 2, then it is ignored (`Grid.isStale`). Dropping hidden blocks at once would break the 1 s match hold every time the arm passes over the board. The core reports a block buried under a stack as visible with age 0, and drops a hidden block itself after 3 s (0.8 s if nothing could be covering it). Blocks in an ignored zone (`Config.ignoreZones`, default the tray; the fake generator's tray) are ignored.
- Stacks: a cell holds a tower, read from each block's `level` field (0 = on the table, 1 = on top of a level 0 block). `Grid.liveGridFrom` builds every cell as a list indexed by level, `{ [0] = {"red"}, [1] = {"teal"} }`. The core owns stack logic, so a block is placed at the level it reports: a level 1 block with nothing under it still sits at level 1. Towers are at most `Config.maxStackGlobal` = 2 high; any block at a level at or above that always counts as extra.
- Doubles rule: if 2+ counted blocks land in the same cell at the same level, that level can never count as correct. `Target.compare` reports the cell in a `doubled` list and returns `clear = false`.
- Roblox boards match the printed sheet, not a mirror image. Row A is the edge where the arm twin sits (+Z) and column 1 is on the tag 0 side (+X). Standing at the row C (tripod) side looking toward row A, A1 is far-left, A4 far-right, C1 near-left, C4 near-right, and the border numbers read 1 2 3 4 left to right. Standing at the arm side looking toward the tripod, tag 0 / A1 is on the right. This is rendering only (`Grid.worldPositionOf`, and `Grid.sheetToWorld` for any sheet point, which the arm twin uses); `Grid.cellOf` from sheet mm is unaffected.

## 2. Colors

`Config.colors = { "purple", "red", "yellow", "orange", "teal", "skyblue" }` with a `Color3` for each. Target generation only uses colors in this list. If vision can't separate orange/yellow or teal/skyblue at the venue, remove them from the list and nothing else changes.

Perception names blocks from its kit list (`robot/perception/config.py` `BLOCK_COLORS`): `red, orange, yellow, teal, purple, light blue`. `Config.perceptionColors` is the one table that maps those six onto `Config.colors` names (`light blue` -> `skyblue`, the rest by the same name). A held block reports `grey` and is ignored anyway.

Any other name on a non-held block is a **misread** (the kit has only the six, and the camera exposure is set so those read correctly): `green`, `blue`, `pink`, or perception's low-chroma fallback `white`, `black`, `grey`. StateStore keeps the name as sent and warns once per name. The LiveBoard draws a misread block mid gray (150, 150, 150) with the white problem outline, and `Target.compare` counts it as `wrong` wherever it sits (`Target.isMisread`: any name not in `Config.colors`), so it blocks the match until the block reads as one of our colors.

## 3. Flow

```
Lobby -> enter Pattern cabinet -> MODE SELECT -> SHIFT (tickets) -> RESULTS -> back to lobby
```

A Papa's-style ticket shift: one timer, target patterns arriving as tickets on a rail, made one at a time.

### Attract mode (Idle)
While the game is Idle (players in the room, before Play), `PatternMatch.Attract` runs a demo loop on the boards, driven by the server so everyone sees the same thing:
- The TargetBoard shows a pattern (`Target.generate`, 2-4 blocks). The LiveBoard places the matching blocks one at a time, `Config.attractPlaceInterval` (0.7 s) apart, each dropping in with a short ease; all bottom blocks first, then the stacked ones on top of them.
- Matched: a short pause, then the celebration (below) with "COMPLETE!", the blocks on both boards swell and shrink away, a short gap, then the next pattern.
- `Config.attractPatterns` (5) patterns per set, at least one with a stack, then a fresh set, forever. Patterns come from `Target.generate`, so they follow the same color rule as tickets (`Config.uniqueColorsPerTicket`).
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
- **A ticket is a target pattern**: `Config.ticketBlocksMin..Max` blocks in total (default 2-4), random colors from `Config.colors`; they can repeat, within a tower too (the rig has more than one cube of a color, and core perception names a repeated color as itself). `Config.uniqueColorsPerTicket = true` is the fallback if repeated colors misbehave at the venue: no color twice in one ticket, towers included, and the block count capped at the number of colors, in towers up to `Config.maxStackGlobal` (2) high. A target cell is a list of colors bottom to top, e.g. `B2 = {"red", "teal"}`. `Target.generate(n, maxHeight, rng, stackChance)` places blocks one at a time: after the first, each block goes on top of a tower that still has room with probability `stackChance`, otherwise on a fresh cell. The stack chance ramps linearly over the shift from `Config.stackChanceStart` (0.2) to `Config.stackChanceEnd` (0.6).
- **Active ticket.** The oldest ticket is active by default; the player can cycle to another one with Q / R or the stack's < > arrows (`TicketCycle` remote). The TargetBoard shows the active ticket. The Live board shows the real table from `StateStore.get().blocks`, redrawn every 0.2 s.
- **Robot OFFLINE.** While `StateStore.status()` is `offline` (no bridge frame for `Config.bridgeStaleSeconds` = 1 s, `blocks_age` over it, or `blocks_age` or `arm_age` null: the server sends null until that part has published once, as in teleop without `--vision`; `StateStore.linkStatus`) the match check freezes: the LiveBoard keeps the last frame, the hold-to-clear count stays at 0, so stale data can't clear a ticket. The shift timer, arrivals and events keep running. When frames come back, matching resumes (the 1 s hold starts over).
- **Compare** runs per cell, per level against the active ticket: `missing` (a target level with no block), `wrong` (wrong color at that level, including a tower built in the wrong order, or a misread color at any cell and level, see section 2), `extra` (a block at a level the target doesn't have, on a non-target cell, or at or above `maxStackGlobal`), `doubled` (2+ blocks at one cell and level), `blocked` (any block on a vanished cell).
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

### Ticket stack HUD (`PatternMatch.Views.Player.PatternHud`, the PlayerView)
- One stack in the bottom left, about 350 x 320 px at 1080p, scaled with the screen height (a UIScale, never below 0.8 of the design size so it stays readable in small windows such as Studio's viewport), clear of the boards in the default camera view, the top-left Roblox chat and buttons, the top-right status panel and the 3D ORDER UP text. On mobile it shares the bottom-left corner with the thumbstick.
- Only the ACTIVE ticket is face up (a bit over half the old rail card's size): ticket number, points, a mini 4 x 3 grid of the pattern (row A on top, columns 1-4 left to right, like the board seen from the row C side; a stacked cell is split, top color over bottom color, with a small "2" badge) and its age. In Hard mode's hidden phase its squares go gray, layout kept.
- Waiting tickets sit behind it as a fanned pile: just their top edges peek out (5 px up and right each, at most 3 edges), with a "+N waiting" badge above the pile (hidden when none wait).
- Cycling: the < and > arrow buttons beside the stack, or the Q and R keys (not E, which is the ProximityPrompt key), make the previous / next ticket active (`TicketCycle` remote, -1 / +1). The order stays oldest first, wrapping around; the active one is just the one on top, and the TargetBoard follows it. The swap takes about 0.2 s: the current card slides out and behind the pile while the next one slides to the front. `PatternMatch.TicketStack` holds the shared rules (keys, wrap-around, badge, pile edges) for the server and the HUD. There is no click-a-card selection.
- Arrivals: a small card flies in and tucks onto the back of the pile, the badge pulses and a "NEW TICKET" chip flashes for 1 s. An arrival never changes the active ticket.
- Completed: the face-up card gets an "ORDER UP! +points" stamp and flies up and off the screen, then the oldest remaining ticket comes to the front. The big "ORDER UP! +points" is the 3D celebration above the boards, so the HUD doesn't repeat it.
- Status panel (top right): mode, shift timer (flashes "+3s" on an ORDER UP), score, tickets completed, the Hard reveal phase, the event banner and the game message. A small badge at the right of the mode line shows the robot link (`payload.robot`): **ROBOT LIVE** (green; any hello source other than `mock`: `teleop`, `follower`, `auto` or anything new), **MOCK** (blue; source `mock`), **OFFLINE** (red; no frame, `blocks_age` over 1 s, or either age null; matching frozen), **NO ROBOT** (gray; the fake generator).

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
| Inverted | banner "ARM INVERTED" | `mirror`, intensity 1, duration 8 (core: shoulder pan inverted) | yes |
| Fog | banner "ARM LAGGING" | `fog`, intensity 0.6, duration 8 (core: follower lags up to 800 ms) | implemented, off by default (add `"fog"` to `Config.events`) |

`Core.Events.fire` sends `{"t":"event","name","intensity","duration"}` through the core's `Bridge`, only for an effect listed in the bridge's `hello.effects`. Otherwise (not listed, fake mode, link down) only the Roblox side runs. The Python side clamps intensity and duration to its own caps.

Each event shows a 2 s warning banner before it starts, so the player can call it out. The operator is blind to the screen, so the callout is the whole point.

## 5. Boards

The cabinet stands in a teen gamer's bedroom. Two chunky wooden game boards sit on one wooden table, with matte foam blocks, warm window daylight and purple / blue LED accents.

- **Room** (`Workspace.Room`, built by `tools/build_room.lua`): four walls, ceiling, wood plank floor (top at Y = 1), a big rug under the table, one window on the -X wall with daylight coming in. Gamer props along the walls, clear of the table and the boards' spin sweep: a gaming desk with monitors and a chair, a bed, shelves, posters, lamps, a beanbag, a plant, and purple LED strips around the ceiling plus blue desk LEDs. All blocky parts, no scripts. The player spawns on a mat (`Room.Spawn.SpawnLocation`) just in front of the Entry pad. No Baseplate, no sky island.
- **Table** (`PatternCabinet.Table`, built by `tools/build_pattern_cabinet.lua`): Top plus four Legs, `#7a5638`, Wood material. Both boards sit on it.
- **Boards** (built by `tools/build_pattern_boards.lua`): each is one chunky raised wooden board (`Slab`, honey wood `#c28a52`, lighter than the table) with a raised, beveled border (`Frame`, `Bevel`, `BevelCorner`). The 12 cell tiles A1..C4 are inlaid wooden squares in two alternating tones, a chessboard: cherry `#9a643a` where row + column is even (A1), maple `#ead1a0` otherwise. They sit on a dark groove layer (`Base`, `#1c120b`, exactly the grid's size, the part `Grid.worldPositionOf` lays the cells out from), and the 0.2 stud gaps between tiles read as thin dark grooves. No labels inside the squares, no paper, no ink lines, no tags. Big burned-in row letters A, B, C are carved into both side borders (row A on the arm side, +Z) and column numbers 1-4 into the row C border (column 1 on the tag 0 side, +X), all readable from the row C side, where they read 1 2 3 4 left to right. Accents: TargetBoard gold `#d9a63a`, LiveBoard green `#3f9a58`, as an inlay line around the squares, a foot band, and the TARGET / LIVE word carved into the row A border (also on the slab's front face). The LiveBoard's slab runs on toward the player as an apron, and the arm twin stands on it.
- **Blocks** are rounded foam cubes 84% of a cell wide (the real 48 mm block on the 57 mm cell), very matte (SmoothPlastic): clones of the rounded-cube MeshPart `ReplicatedStorage.PatternMatch.BlockMesh` (Creator Store asset 6416975593, stored by the cabinet build tool; plain Parts if it is missing). Block colors are Apprentice's palette (section 8).
- **Arm twin** colors: off-white links `#e9e6df`, dark joints `#2a2d33`, SmoothPlastic.
- **Lighting** (`tools/setup_lighting.lua`): `LightingStyle = Realistic`, `GlobalShadows` on. A warm late-afternoon sun low in the west (-X) streams through the window onto the rug and the TargetBoard; indoor ambient is a touch cool; a warm SpotLight in the ceiling lamp keeps the table bright; mild Bloom makes the Neon LED strips glow.
- **Depth of field** (`Views.Player.PatternWorld.CabinetFocus`, player and spectators): drives `Lighting.CabinetFocus`, a DepthOfFieldEffect, every frame. FocusDistance is the camera's distance to a point just above the table's center, and InFocusRadius (24) keeps both boards and the arm sharp while the room behind blurs softly (FarIntensity 0.18). During the mode select shot (LocalPlayer attribute `PatternShot`) it eases to a stronger blur (radius 20, far 0.5, near 0.1).
- Two boards in the world, side by side, 3D parts, not GUI: TargetBoard and LiveBoard. Player walks around them freely.
- Only the TargetBoard spins: click anywhere on it to turn it 90 degrees around its vertical center axis, 0.3 s. The ClickDetector (`SpinClick`) sits on the whole TargetBoard Model, not just the base, because the tiles cover the base's top. Spins run on the server so everyone sees the same orientation, queue up, and wait while a tremor is on. The LiveBoard has no ClickDetector and `BoardSpinner` ignores requests for any board without one, so the LiveBoard and the arm twin always stay fixed, matching the real table. Board spacing is unchanged.
- Both boards draw blocks from the same pool (`PatternMatch.BlockPool`): one block part per cell and level (12 cells x `maxStackGlobal` levels, named `B2` and `B2_1`), made once, each sitting one block height above the one below, recolored or hidden, never created per tick.
- LiveBoard: 12 cell tiles plus a block at each cell and level with a counted block on the table, colored from `Config.colors` (a misread color mid gray). Vanished cells use `Transparency = 1`: the inlaid square disappears and the dark groove layer under it shows as a hole. The white problem outline (extra, doubled, blocked, misread) goes on the specific block part at fault; a block above the pool's top level is shown on the top part.
- TargetBoard: 12 wooden squares (never recolored) plus a tower of blocks, identical to the LiveBoard's, on each target cell in its target colors; non-target cells have no block. In hard mode the target blocks are outlined, and in the hidden phase every level turns mid gray (150, 150, 150, same blocks, recolored), which reads as gray on both wood tones. Outside the shift the TargetBoard is empty.

## 6. Robot twin (stick figure from arm.points)

The twin is drawn from the bridge's `state.arm.points`: the arm as world points in sheet mm, base to tip (`shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, tip`), already through the real arm's URDF and fitted calibration in Python. No link lengths, joint signs or offsets are involved.

- Server (`PatternMode`): 20 times a second `ArmTwin.Stick.payload` maps each point to world studs over the LiveBoard with `Grid.sheetToWorld` (same layout and scale as the board: `Config.boardCellStuds` per cell, so x, y and z all scale by 4 / 57.15 studs per mm and the tip lands over the cell it is over on the real sheet) and sends `{ foot, points, scale }` on the `ArmPose` UnreliableRemoteEvent. Nothing is sent while the attract demo runs, while the link is OFFLINE, or while `arm_age` is over 1 s.
- Client (`Views.Player.PatternWorld.ArmTwinClient` -> `ArmTwin.Stick.attach`, player and spectators only): an `ArmStick` Model in `PatternCabinet` with an off-white cylinder per segment (30 mm thick), a dark ball on each point (40 mm, the tip 26 mm) and a base column (80 mm) from the paper up to the first point. It eases toward each sample (and jumps if the point count changes).
- Rest pose: with no arm data (no sample yet, an empty one, or none for `Stick.STALE_SECONDS` = 1 s) the stick eases into the folded `Config.twinRestPose` (real-arm degrees through `ArmTwin.Rig`'s forward kinematics), standing at the parts-built rig's pivot on the apron.
- One arm only: the parts-built Motor6D rig (`ReplicatedStorage.ArmTwin`, clone `LiveBoard.ArmTwin`) stays in the place, hidden on every client, and only gives the rest pose its place. Its joint-angle driver (`ArmTwin.Driver.attach`, `Config.twinJoints`) is kept but not used. The core's `SkyArm` is not used: it draws in the core's own frame (`Mapping`: sheet x -> world X, sheet y -> world Z at 0.46 studs per mm from the world origin), which is mirrored and scaled differently from the LiveBoard (column 1 at +X, row A at +Z), and it can't be re-placed without editing core files; running it as well would draw a second, giant arm.
- The fake generator's arm is `Config.twinRestPose` plus small waves, turned into sheet-mm points with `ArmTwin.Rig`, its base centered on the grid's width `Config.twinBaseOffsetMm` (90 mm) before row A.

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
  PatternMatch.Grid (ModuleScript)        sheet mm -> cell, cell / sheet point -> world position
  PatternMatch.Target (ModuleScript)      generate, compare
  PatternMatch.LiveBoard (ModuleScript)   pooled block parts on the LiveBoard
  PatternMatch.Game (ModuleScript)        state machine: Idle, ModeSelect, Shift (tickets), Results
  PatternMatch.Attract (ModuleScript)     the Idle demo loop on the boards
  PatternMatch.Celebrate (ModuleScript)   the shared COMPLETE! / ORDER UP celebration
  PatternMatch.TicketStack (ModuleScript) ticket stack rules shared by the server and the HUD
  PatternMatch.PatternEvents (ModuleScript) event scheduler + vanish / tremor / inverted
  PatternMatch.TargetBoard (ModuleScript) target colors, Hard-mode hidden look
  PatternMatch.Remotes: PatternState (BindableEvent, server-only state changes)
  Core.StateStore (ModuleScript)          adapter over ServerScriptService.Bridge, fake generator fallback
  Core.Events (ModuleScript)              Events.fire -> Bridge event frame (if in hello.effects)
  ArmTwin (Model, parts-built SO-101, hidden in game) with Rig (geometry, FK, builder), Driver (server
    broadcast; client Motor6D easing, unused) and Stick (the stick-figure twin from arm.points) ModuleScripts;
    the LiveBoard holds a clone without the modules
  PatternMatch.Remotes: ArmPose (UnreliableRemoteEvent, arm points as world studs 20 Hz, server -> clients)
  PatternMatch.Remotes: PatternUI (server -> player, spectators: HUD payload), RobotUI (server -> robot:
    Game.robotPayload), PatternRefresh (any client -> server: send me the current payload), PatternPick
    (player -> server: mode), TicketCycle (player -> server: -1 / +1 through the tickets)
  PatternMatch.Debug (BindableEvent, server only: { op = "start", mode } / { op = "endShift" }, testing)
  PatternMatch.Views
    PlayerView (ModuleScript)              clones Player.* into PlayerGui on enter, removes them on exit
    RobotView (ModuleScript)               the robot's blind card: timer, score, ORDER UP; camera away from the boards
    Player (Folder of inert templates, run only once cloned into PlayerGui)
      PatternHud (ScreenGui + HudClient)   ticket stack, shift timer, score, event banner, results, Q / R
      PatternModeSelect (ScreenGui + ModeSelectClient)
      PatternWorld (Folder): CabinetFocus (depth of field), ArmTwinClient (stick-figure twin, ArmStick)
  Core.Roles, Core.GameRegistry, Core.Config (ModuleScripts)  roles and the active game (docs/roles.md)
  Core.Games.PatternMatch (ModuleScript)  Pattern Match's registry entry (lobby = true)
  Core.Views.LobbyRobotView (ModuleScript) the robot station while no game is active
  Core.Remotes: RoleSwap (RemoteEvent, F8, Studio only), ViewSync (UnreliableRemoteEvent, player camera -> spectators)
ServerScriptService
  PatternMode (Script)                     wires the prompt and remotes to PatternMatch.Game (player role only)
  CoreRoles (Script)                       assigns roles, spawns the player's character only, relays ViewSync
  Bridge (ModuleScript)                    the core's roblox/Bridge.lua (mirrored as is): the one WebSocket
StarterPlayer.StarterPlayerScripts
  RoleClient (LocalScript)                 shows the view for this client's role and the active game
Lighting
  CabinetFocus (DepthOfFieldEffect), Bloom, Atmosphere, SunRays, Sky
Players.CharacterAutoLoads = false         (CoreRoles loads characters)
Workspace.RoleStreamFocus                  (made by CoreRoles) streaming focus for clients with no character
```

## 8. Config defaults

```lua
return {
  useBridge = true,                    -- Core.StateStore reads the core's Bridge; false = fake generator only
  bridgeUrl = "ws://localhost:8765",   -- or the robot laptop's LAN IP
  bridgeHelloSeconds = 3,              -- no hello by then at server start: fake generator for this session
  bridgeStaleSeconds = 1,              -- no frame, or blocks_age over this (or none yet): OFFLINE (matching freezes)
  staleBlockSeconds = 2,               -- a visible = false block (hidden by the arm) still counts until its age passes this
  -- perception's names for our six blocks -> Config.colors names; any other name is a misread (gray, wrong)
  perceptionColors = { red = "red", orange = "orange", yellow = "yellow", teal = "teal", purple = "purple",
                       ["light blue"] = "skyblue" },
  gridCols = 4, gridRows = 3,          -- fallback until hello.space.grid: columns 1-4, rows A-C
  gridOriginMm = Vector2.new(25.4, 22.225), -- fallback: sheet mm of cell A1's outer corner (nearest tag 0)
  cellSizeMm = 57.15,                  -- fallback: measured on the printed sheet
  flipX = false,                       -- true mirrors columns (1 <-> 4) if the sheet or tags turn out reversed
  flipY = false,                       -- true mirrors rows (A <-> C)
  cellTolerance = 1.0,                 -- a block anywhere inside a cell counts (lower it to ignore cell edges)
  maxStackGlobal = 2,                  -- hard cap on tower height; a block at level >= this always counts as extra
  ignoreZones = { tray = true },       -- block zones that never count (plan.md: the inventory tray maps to nothing)
  boardCellStuds = 4,                  -- studs per grid cell on the boards; with the cell size this is the mm -> stud scale
  twinBaseOffsetMm = 90,               -- built arm twin's base center, from the grid's row A edge toward the operator
  twinStickMm = { link = 30, joint = 40, tip = 26, base = 80 }, -- stick-figure twin thicknesses (sheet mm)
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
  uniqueColorsPerTicket = false,       -- true: no color twice in one pattern (tickets and attract), towers included;
                                       --   a fallback, since core perception names repeated colors
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
  debugAutoSolve = false,              -- testing (fake generator only): rebuilds the board for the active ticket 3 s after it becomes active,
                                       -- reusing the blocks already there (leftovers go to the tray)
  debugFastTimers = false,             -- testing: every game timer (shift, ticket arrivals, events, reveal) runs 4x faster
  debugForceMode = nil,                -- testing: "easy" or "hard" makes ModeSelect pick that mode; nil picks Easy
  debugEventEvery = nil,               -- testing: seconds between events in both modes, instead of easy/hard.eventEvery
  hard = { showSeconds = 5, hideSeconds = 5, eventEvery = 30 },
  easy = { eventEvery = 45 },
  vanishSeconds = 6, vanishCount = { 1, 2 },
  events = { "vanish", "tremor", "inverted" }, -- "fog" also works; durations (4 s, 8 s, 8 s) live in PatternEvents
  twinJoints = { shoulder_pan = {sign=1, offset=0}, shoulder_lift = {sign=1, offset=0}, elbow_flex = {sign=1, offset=0},
                 wrist_flex = {sign=1, offset=0}, wrist_roll = {sign=1, offset=0}, gripper = {sign=1, offset=0} },
  -- folded rest pose, shown while there is no arm data; same units as StateStore.arm, run through twinJoints
  twinRestPose = { shoulder_pan = 0, shoulder_lift = 125, elbow_flex = -128, wrist_flex = -76, wrist_roll = 0, gripper = 0 },
}
```

## 9. Build order for the execution session

1. Config, Grid, Target modules with unit-style tests run through `execute_luau` (mm -> cell edge cases, compare with extra block, compare with vanished cell).
2. LiveBoard renderer from `StateStore.blocks`, driven by the core's mock mode.
3. PatternMode state machine with Easy only, no events: mode select stub that auto-picks Easy, rounds, intermission, results.
4. Hard mode show/hide cycle.
5. Events: vanish first (Roblox-only), then tremor, then inverted.
6. Mode select screen with camera hover, tiles, countdown.
7. Click-to-spin boards.
8. ArmTwin parts model + TwinDriver, tune signs against the real arm.
9. Sign and HUD polish.

## 10. Agree with the core guy

- Settled by the bridge: the grid comes from `hello.space.grid` (3 x 4, origin (25.4, 22.225) mm, 57.15 mm cells, matching Config); `earthquake`, `mirror` and `fog` all exist (`hello.effects`), and `mirror` inverts shoulder pan.
- Still open: whether `mirror` should also lower the speed cap; camera exposure locked at the venue, and a color test for all six blocks before targets use them.

## 11. Robot bridge (core)

The core's Roblox files live at `roblox/Bridge.lua`, `Mapping.lua`, `SkyArm.lua`, `BlockSync.lua` and `Main.server.lua` (from `origin/robot-roblox-bridge`; wire format `PROTOCOL.md`). Pattern Match uses only `Bridge`, as is, as `ServerScriptService.Bridge`. `Main`, `SkyArm`, `BlockSync` and `Mapping` are not in the place: `Main` would build the Robo-Obby scene (a giant Sky Arm, rideable block platforms, a sheet pad, raised jump height) on top of the cabinet.

- **One socket.** Only `Core.StateStore` calls `Bridge.connect(Config.bridgeUrl)`, once, on the server. `Bridge` stores only the newest state frame and hands it to `onState` on Heartbeat (PROTOCOL.md backpressure); StateStore converts it (colors mapped) and keeps it for `StateStore.get()`. Nothing else opens a WebSocket, and `Core.Events` sends through the same `Bridge`. Don't `require(Core.StateStore)` from a command bar or MCP execute_luau while playing: that makes a second module copy, which opens a second socket.
- **Hello.** `hello.space.grid` -> `Grid.setGeometry`; `hello.source` -> the badge; `hello.effects` -> which events go to the arm. A reconnect sends a new hello, which is applied again.
- **Fallback.** `Config.useBridge = false`, no `ServerScriptService.Bridge`, or no hello within `Config.bridgeHelloSeconds` (3 s) of server start: the fake generator (fake arm, Debug hook, `debugAutoSolve`) runs instead, badge NO ROBOT. This is decided once. After a hello, a dead link is OFFLINE (matching frozen, twin at rest), never fake data, and it recovers by itself when the server comes back (`Bridge` retries every 2 s). A hello that arrives after the fake took over switches to the bridge, but only outside a shift.
- **Attract mode** never reads `StateStore` (the LiveBoard isn't drawn from it and no arm points go out while the demo runs).
- `HttpService.HttpEnabled` must stay true in the place.
- Running the mock: `python -m bridge.main --source mock` then `python -m bridge.test_link` (14 checks). It runs on a laptop with no robot: with no `lerobot` or no follower calibration file, `robot/workspace.py` `calibrated_ranges()` returns `{}` and the mock solves on the URDF's joint limits. Teleop refuses to start without the ranges (they clamp the real arm). Python tests: `python -m bridge.test_world` (block tracker) and `python -m robot.perception.test_naming`.
- Core changes made for Pattern Match (2026-10-18, on `integrate-bridge`): `robot/perception/naming.py` lets two confidently matched blocks share a color name (it used to rename the second one); `bridge/world.py` keeps same-color neighbours and same-color stacks apart (a buried cube loses the camera blob to the cube on top; a claimed pick loses it to the cube left underneath, and a blob another track owns is not "left behind"); `robot/workspace.py` falls back to URDF limits with no calibration; `bridge/producers/teleop.py` refuses to run without calibrated ranges; `roblox/Bridge.lua` logs "connected" only when the socket opens (`Opened`). What an overhead camera still can't tell apart: a same-color cube stacked or unstacked by hand (no arm), and a jaw closing on air over a same-color stack. Tickets avoid neither; with the arm doing the stacking both are rare.

## 12. Roles: player, robot, spectators

Core roles and the game registry are in docs/roles.md. For Pattern Match:

- **Player** (first client): everything above. The HUD, the ticket stack, mode select, the Play prompt, the depth of field on the table, the stick arm twin and the boards. In the lobby (no active game) too, since Pattern Match is the lobby game (`lobby = true`), so the player sees the attract demo, the idle HUD message and the arm twin as before.
- **Only the player changes the game.** The Play prompt, `PatternPick`, `TicketCycle` and the TargetBoard's `SpinClick` are wrapped in `Roles.guard`; the robot's and spectators' calls are dropped and logged.
- **Active game:** Pattern Match is the active game (`Core.GameRegistry`) from mode select until Results end (`Game` opts.onActive).
- **Robot** (second client): no character. In the lobby, `Core.Views.LobbyRobotView` (orbit, "ROBOT STATION", the link badge). Once the player presses Play, `Views.RobotView`:
  - **Camera:** fixed on the back of the room (from (12, 9, -53) toward the gaming desk at z -70). The whole cabinet, the boards and anything above them (the ORDER UP text, the attract sign) are behind the camera, at every moment including celebrations. A test checks every corner of the cabinet's bounding box (and 12 studs above it) is behind the shot.
  - **Blur:** the room is blurred like the mode select shot (Lighting.CabinetFocus: far 0.5, near 0.1, focused just in front of the camera) behind a dark overlay.
  - **Card:** "PATTERN MATCH", "You're the robot. You can't see the board. Listen to your partner.", then:
    - mode select: "Your partner is picking a mode. Get ready!"
    - the shift: the shift timer and "Score N   Tickets M"
    - an ORDER UP: a big "ORDER UP! +points" flash above the card
    - Results: "SHIFT OVER" and "Final score N" only
  - **What reaches the robot:** its client never gets the full HUD payload. The server sends it `Game.robotPayload` (state, timer, score, tickets done, latest ORDER UP seq + points, link status) on `RobotUI`; the tickets, the target, the reveal phase, events and vanished cells never leave the server for it. No HUD, mode select, ticket keys, depth-of-field script or stick arm runs on its client.
- **Spectators:** the PlayerView read only (no Q / R, arrows or mode picks; no camera shake), with the camera following the player's.
