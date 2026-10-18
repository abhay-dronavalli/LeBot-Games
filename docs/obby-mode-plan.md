# Obby as an arcade mode: conversion plan

Oct 18, 2026. **Built (files only, not yet run in Studio): see [As built](#as-built) at the end.** The plan below is
kept as written, except the map now goes to **OriginZ = 1100**, not 800: Dragon Arena spans about Z 520..880.
Contract: [arcade-plan.md "Mode contract"](arcade-plan.md#mode-contract-send-to-teammates-today). Reference mode:
`roblox/ServerStorage/Modes/PatternMatch/Module.lua`. The Back to Lobby pad is on `origin/lobby-integration` (2d220d0).

## 1. Which branch

- **`origin/obby_kushi` is current** (tip `9c89ce4`, 05:46 today).
- `origin/obby-bay-extension` (tip `35badc7`) is **fully merged** into obby_kushi in `70b9ca6`. It has 0 commits obby_kushi
  lacks, and obby_kushi is 20 commits ahead. Ignore it.
- Both branched from main at `6e7c4ed` (PR #3). `obby-mode` has the older PR #3 copy of `lebot_obby/` and none of the 20
  newer commits.
- At freeze, take `lebot_obby/` and `obby_planmds/` from obby_kushi's tip. Don't merge the branch: it also touches
  `tools/` and `build/`.

## 2. Geometry

- The warehouse shell, the 4 bays (`Workspace.Warehouse.BayNN` with `CrateAnchors.Cell_c_r`), catwalks, racks and
  `SkyRails` are **baked into `lebot_obby/Place1.rbxl` only**. The scripts that generated them were never kept (lebot_obby/README).
  The obstacles themselves (`BayNN.Obstacle`) and `SkyArmRig` are built by scripts at runtime.
- The place file was last saved at 04:09 (`01e030b`). The dark room and overseer commits (04:21–05:46) came after it. **Ask
  Kushagra for a fresh save at freeze.**
- How it gets into the arcade: open Place1.rbxl, then save `Workspace.Warehouse` to a file (.rbxm, gitignored, never committed). In
  `places/LeBot_Arcade.rbxl`, insert it as `ServerStorage.Modes.Obby.Map` (a Model containing `Warehouse`). Leave
  behind `ServerStorage.OutOfScope` (the parked bays 5–9), the obby's `SpawnLocation` and its `Lighting`.
- **Offset:** the obby's code assumes bay 1 starts at Z = 0 and X runs 0–32. `(0, 0, 800)` is a pure Z shift, so:
  bake it once in Edit mode (`Map:TranslateBy(Vector3.new(0, 0, 800))`) and add `Config.OriginZ = 800`. The
  course then spans roughly X −10..42, Z 790..935, Y −48..48. That clears Pattern Match (Z −400) and Flood (X 400). Check that
  nothing in the Workshop sits in that box.
- Set `Map.ModelStreamingMode = Persistent`. Add three parts to the map: `Start` (on the entrance buffer, facing +Z),
  `Finish` (a zone in the finale buffer past bay 4's exit door) and `LobbyPad` (beside Start).

## 3. Every script and the edit it needs

Layout in the arcade:

- `ServerStorage.Modes.Obby` holds `Map`, `Module` (new) and `Server/` (the server ModuleScripts).
- `ReplicatedStorage.Obby` holds `Config`, `BayData`, `CrateDefs`, `Mapping`, `Remotes/` and `Views/`.
- `ReplicatedStorage.Core.Games.Obby` is the registry entry.

The namespacing matters because the arcade already has `ServerScriptService.Bridge` (the core's link), and generic names
like `Config`, `Remotes`, `Mapping`, `SkyArm` and `BlockSync` collide.

**Lifecycle trick (the fast part):** `Start` clones `Server/` fresh each round and requires the clones. Every module
then has fresh state and fresh BindableEvents, so listeners left from last round hang on dead events and never fire. What
still needs explicit cleanup is anything on long-lived signals: `RunService`, `Players`, remote `OnServerEvent`, and
`while true` loops. Each module turns its top-level body into `start(session)`, where `session.track(conn)` collects connections
and `session.alive` stops loops. `Stop` disconnects everything, sets `alive = false`, then destroys the clone and the map.
Inside `Server/`, requires change from `ServerScriptService:WaitForChild("X")` to `script.Parent.X`, and from
`ReplicatedStorage:WaitForChild("Config")` to `ReplicatedStorage.Obby.Config`.

| Script (obby_kushi) | What it does | Edit |
|---|---|---|
| `ReplicatedStorage/Config` | All tunables | Add `OriginZ = 800`. Set `FeedMode` at runtime (below). Set `DebugMode = false` and add `ArcadeDebug = false` (see 7) |
| `ReplicatedStorage/BayData`, `CrateDefs` | Bay definitions, crate looks | Move only |
| `ReplicatedStorage/Mapping` | Sheet mm → studs, origin from the active bay's `Cell_0_0` | Move only (it reads anchors, so the offset is free) |
| `ServerScriptService/Bridge` | Its own WebSocket | **Delete.** The core's link replaces it |
| `ServerScriptService/BridgeFeed` | hello → `Mapping.setSpace`; state → SkyArm tip + `BlockSync.applyBlocks` | `start(session)`: `Mapping.setSpace(Core.StateStore.hello().space)` once. Swap `Bridge.onState` for a tracked `Shared.StateStore.Updated` listener that reads the raw mm frame `Core.StateStore.get()` (Shared wraps the same store: the tip is `arm.tip` or the `"tip"` point, plus `blocks`, `blocks_age`). Remove `dial`, `Bridge.disconnect` and the CONTROLLER ONLINE poll; use `Shared.Bridge.isOnline()` |
| `ServerScriptService/RunControl` | Feed mode, active bay, rebuild hooks | `activeBayModel()` reads the session's `Warehouse`. At Start, `feedMode = Shared.Bridge.isOnline() and "live" or "solo"`, fixed for the round. Solo is the playable fallback when no robot is connected |
| `ServerScriptService/BlockSync` | Cell → world, crate delivery, placement guards | Parent the `Goal` attachment (line ~447, in `workspace.Terrain`) under a part in the map, or destroy it on arrival and in Stop |
| `ServerScriptService/SkyArm` | Builds `Workspace.SkyArmRig`; Heartbeat drives it | Parent `SkyArmRig` into the map. `session.track` the Heartbeat (line 303) |
| `ServerScriptService/ArmMirror` | Literal arm (only with `ArmStyle = "mirror"`) | Move only. It's unused with `"gantry"` |
| `ServerScriptService/HazardManager` (Script, 2.7k lines) | Builds the 4 obstacles, solve detection, objective HUD, R reset | `bayZStart(i)` adds `Config.OriginZ`. Every Z goes through it, and X needs nothing. `occupantsOf`/`publishObjective` loop over **session runners**, not `Players:GetPlayers()`. Void's `while true` HUD loop (line 1134) becomes `while folder.Parent`. **Dark room:** replace the `Lighting` dim (lines ~2277–2300) with a client-side darkening (see 7). Move the `DebugHotkey` "R" handler behind `ArcadeDebug`. Expose `RunControl.bayState` for the win check |
| `ServerScriptService/ActiveBayTracker` | Mat follows the furthest runner | `bayAt(z - Config.OriginZ)`. Runners only. Track the Heartbeat |
| `ServerScriptService/DebugMode` | Solo crate source: cell editor → SkyArm deliveries | Keep it (it **is** solo play), minus its `Config.DebugMode` early return. Replace `FireAllClients` with firing to the runner. Track `OnServerEvent` |
| `ServerScriptService/DebugMenu` | Teleport/start run/full reset (F2) + `DebugStatus`/`BayCells` broadcasts | Split it. **Status** (`snapshot`, `pushStatus`, `BayCells`) moves into Module, always on, sent to the runner and the robot role; the robot view needs it. **Commands** stay behind `ArcadeDebug`. Replace `startCFrame()` (any `SpawnLocation` in Workspace, which would be the Workshop's) with `Map.Start`. Add `OriginZ` to `approachCFrame` |
| `ServerScriptService/GhostMode` | Q = fly + invincible | Behind `ArcadeDebug` only. Not shipped in rounds |
| `StarterPlayerScripts/ObjectiveHud` | The task panel and countdown | Becomes a template in `Views/Player`, cloned into PlayerGui by the PlayerView on enter and destroyed on exit (the PatternMatch PlayerView pattern) |
| `StarterPlayerScripts/DebugCellEditor` | The 4×3 click grid, plus hotkeys 1–9 N T K H M R | Its grid is solo play. Clone it only when `feedMode == "solo"`. Strip the hotkeys (R rebuilds every bay) unless `ArcadeDebug` |
| `StarterPlayerScripts/DebugMenu` (client) | F1/F2 panel | Not shipped. Only cloned when `ArcadeDebug` |
| `StarterPlayerScripts/GhostControl` | Ghost flight | Not shipped |
| `StarterPlayerScripts/OverseerCam` | Player 2's top-down view of the active bay (V) | Becomes the **RobotView** (section 5) |
| `Remotes` (place-only folder) | `CellEdit`, `CellsUpdated`, `DebugHotkey`, `GhostToggle`, `Objective`, `DebugCommand`, `DebugStatus`, `BayCells` | Module creates them under `ReplicatedStorage.Obby.Remotes` when it loads (getOrCreate, like PatternMatch) |

**New `Modes/Obby/Module`** (copy PatternMatch's shape):

- `Start(players)` clones the map and `Server/`, then sets feed mode, builds the bays, and places runners on `Start`.
- It also opens the objective channel and starts the run clock and the finish/leaver loop (0.25 s).
- Active game: either call `GameRegistry.setActive("Obby")` and add `Obby` to `SELF_MANAGED` in `ArcadeActiveGame`, or make no
  call and let ArcadeActiveGame set it, like Flood. Pick the second: it's zero code.
- `Stop()` disconnects everything, clears every runner's HUD, destroys the map and the clone, and sets `RunControl` to nil.
- **Deaths:** the arcade respawns a dead runner in the Workshop. Track `CharacterAdded` per runner, then call
  `RunControl.rebuildBay(furthestBay)` and teleport them to `approachCFrame(furthestBay)`. That's a checkpoint, using DebugMenu's
  `placePlayer`.

## 4. Win condition and MaxDuration

The obby has no finish, run clock or win screen today (obby_planmds/README "Not built"). Add them in Module:

- **Win:** a runner's root is inside `Map.Finish` (a polled box check, not `Touched`) after bay 4 reports `solved`.
  They get `{won = true}`.
- **Lose:** the run clock (`Config.FullRunSeconds`, 480 s, already in Config and unread) runs out, or the runner left or took
  the lobby pad. They get `{won = false}`.
- The round ends when every runner has finished or left, or the clock hits 0. Show a 4 s "COURSE CLEAR" / "TIME'S UP"
  objective payload, then fire `Finished` once with one entry per player passed to Start.
- **`Mode.MaxDuration = Config.FullRunSeconds + 20`** (500). This must be set: the arcade's default timeout is 180 s, which
  would cut a run mid-course. Rough course estimate: saw ≤ 75 s, void ~45 s, laser 6–8 moves at ~12 s each, dark room ~90 s.
  That's about 5 min, so 480 s leaves room for deaths. Retune after one real run.
- `DisplayName = "Robo-Obby"`, `WinsToUnlock = 0`.

## 5. Robot view

The operator's job is to put real cubes in the right cells of the active bay. They need the active bay from above with x-ray
walls and roof (bay 4 has a roof at y = 14), the labelled 4×3 cells, the wanted cells, the occupied cells, where the runner
is, and what the bay is asking for. `OverseerCam` already draws all of that except the last item.

- Turn `OverseerCam.client.lua` into a ModuleScript `ReplicatedStorage.Obby.Views.RobotView` with `enter()`/`exit()`.
  `enter` builds the GUI and overlay and turns the view on (no V key). `exit` disconnects RenderStepped, the inputs and the
  status listeners. It also stops the `while true` paint loop (gate it on a flag), restores `LocalTransparencyModifier`
  on everything it ghosted, destroys the overlay and GUI, and puts the camera back (FloodRobotView's `savedCamera` pattern).
- The robot has **no character**. Drop the `player.CharacterAdded` re-assert, and highlight the runner as the player with
  `Role == "player"`. RoleClient already sets a scriptable camera for the robot.
- It reads `activeBay`, `solveCells`, `resetToken` and the occupied cells from the status/`BayCells` remotes that Module now sends
  (section 3).
- **Objective for the robot:** `publishObjective` only reaches players standing in a bay, so also send the runner's
  current payload to the robot-role player, and show it in RobotView. Laser walk and dark room depend on the operator reading it.
- Registry entry `ReplicatedStorage.Core.Games.Obby`:
  `{ id = "Obby", name = "Robo-Obby", lobby = false, playerView = Obby.Views.PlayerView, robotView = Obby.Views.RobotView }`.
  The PlayerView clones ObjectiveHud, plus the cell editor in solo. With `ctx.readOnly` (spectators) it clones the HUD only.

## 6. Lobby pad and PlayerLeft

- `Map.Warehouse.LobbyPad`: a BasePart tagged `LobbyTeleporter` beside `Start`. The arcade styles it and moves players on it.
  Module sets `Enabled = true` at Start and `false` once the result is decided, so nobody loses on the win screen. The bays
  seal behind the runner (saw and dark room entry gates), so mid-course you can't get back to it anyway.
- `Mode.PlayerLeft(player)`: mark the player left (`won = false`), clear their HUD, and stop following them for
  ActiveBayTracker and the respawn hook. If no runners are left, finish right away. Server leavers go through the same check in
  the 0.25 s loop (PatternMatch's `checkLeavers`).

## 7. Risks

- **The whole arcade runs in Studio**, because the robot socket only works there. So `RunService:IsStudio()` is always true and
  **can't gate debug keys**. Use a single `Config.ArcadeDebug` (default false). Behind it go: F1/F2 (F2 = full reset with
  `LoadCharacter`), DebugMenu commands (teleport, startRun, resetAll, feedMode), Q ghost, the cell editor's hotkeys and
  HazardManager's R. Remove them from the client templates so the keys don't exist.
- **Scripts that assume they're the only game:**
  - Every `Players:GetPlayers()` loop in HazardManager, ActiveBayTracker and DebugMode would treat Workshop players as runners.
  - `FireAllClients` in DebugMode and DebugMenu would show the HUD and grid to the whole server.
  - `startCFrame()` grabs any SpawnLocation it finds.
  - `Workspace.SkyArmRig` and the `Terrain` goal attachments sit outside the map.
  - The dark room changes **global `Lighting`**, which would black out the Workshop and the robot's view.
  - `GhostMode` hooks `PlayerAdded`.
  - The module-level BindableEvents leak unless `Server/` is cloned fresh per round.
- **Dark room without Lighting:** move the darkness to the runner's client. Put a `ColorCorrectionEffect` under
  `workspace.CurrentCamera` (Brightness ≈ −0.6, Saturation −0.5), switched by a `Dark` attribute HazardManager sets on the bay
  instead of touching Lighting. The sconces are PointLights, so they still stand out. The screws stay hidden by `isLit` regardless.
  Tune it by eye. If it reads too flat, ask the arcade owner for a sanctioned hook rather than touching Lighting.
- **1.5× characters** (`CharacterScale` keeps JumpHeight 7.2 and WalkSpeed 16). Foot rise is unchanged: 1 cube (6.72) is
  still climbable and 2 (13.44) still isn't, and the void's 16-stud gap is still unjumpable. What changes is body size, about 3 × 7.5
  studs.
  - The saw wall's **exact-stand-level levers**: the ProximityPrompt is measured from a root that's about 1.5 studs higher, so a
    lever might be throwable one level too low.
  - The laser walk: a wider body on an 8-stud safe cell can clip a live neighbour.
  - The dark room: a 14-stud ceiling is fine.
  - Test these three first. If they fail, add a per-player `NoScale` attribute that CharacterScale respects, and set it
    in Start.
- **Single runner:** gates seal behind the first runner, so a second runner can be locked out. Roles normally give exactly
  one character (the player role), so that's fine. With no roles assigned (no CoreRoles), allow one runner and start the
  others as spectators.
- **Live mode is untested on hardware** (robot-link.md). Solo is the fallback whenever the core link isn't live/mock at Start.
- **The arcade sends `{t = "mode", name = "obby"}`.** The Python side needs a mapping for `obby`, or it keeps the lobby zone.

## 8. Execution checklist (after the freeze)

1. Kushagra pushes final scripts and a fresh `Place1.rbxl` to obby_kushi. Note the tip hash here.
2. `git checkout origin/obby_kushi -- lebot_obby obby_planmds` on obby-mode.
3. In Place1: save `Workspace.Warehouse` to a file. In `places/LeBot_Arcade.rbxl`, create `ServerStorage.Modes.Obby`, insert it as
   `Map/Warehouse`, run `TranslateBy(0, 0, 800)`, set Persistent, and add `Start`, `Finish` and `LobbyPad` (tagged, `Enabled`).
4. Make the repo layout: `roblox/ServerStorage/Modes/Obby/{Module.lua, Server/*.lua}` and
   `roblox/ReplicatedStorage/Obby/{Config, BayData, CrateDefs, Mapping}.lua` plus
   `Views/{PlayerView, RobotView}.lua`, `Views/Player/*` and `roblox/ReplicatedStorage/Core/Games/Obby.lua`.
5. Do the edits in section 3, mechanical ones first: requires, delete Bridge, `OriginZ`, runners-only loops, no
   `FireAllClients`, SkyArmRig into the map, `ArcadeDebug` gates.
6. Write Module (Start/Stop/PlayerLeft, run clock, finish check, respawn checkpoint, `MaxDuration`).
7. BridgeFeed onto Core/Shared StateStore. Dark room onto the client ColorCorrection.
8. RobotView from OverseerCam. PlayerView with HUD and solo grid. Registry entry.
9. Push the sources into the arcade place (tools/studio_sync.py over local HTTP).
10. Test solo (no robot):
    - Play 3 runs in a row from the Obby cabinet: win, die and checkpoint, time out.
    - Then 3 mixed with Pattern Match and Flood.
    - Check: Wins only for winners, no `SkyArmRig`/HUD/darkness left in the Workshop, 0 errors in Output.
11. Test the lobby pad mid-round (lose, round ends) and a server leave.
12. Test with the mock bridge (`live` feed): crates follow mock blocks and the robot view shows the active bay.
13. Commit the sources and push. Save the arcade place (it's gitignored except `places/LeBot_Arcade.rbxl` per the lobby branch).

---

## As built

Done on `obby-mode`, Oct 18. The branch merges `origin/lobby-integration` (2d220d0) and `origin/obby_kushi` (d8c0f94,
the newest `Place1.rbxl`) with no conflicts, and `roblox/` is identical to lobby-integration apart from the files below.
**Files only.** None of it has been run in Studio yet, and there is no Luau checker here, so the first install will
surface any typos in Output.

Kushagra's standalone copy stays in `lebot_obby/`, and he can keep working there. The arcade copies listed below started
as his files with minimal edits, so a later design change can be ported by diffing his file against its arcade twin.

### Where everything is

| Repo | Studio | What |
|---|---|---|
| `roblox/ServerStorage/Modes/Obby/Module.lua` | `ServerStorage.Modes.Obby.Module` | The mode: Start/Stop/PlayerLeft/IsDecided, run clock, finish, respawn checkpoint, lobby pad, runner scale. `DisplayName "Robo Obby"`, `WinsToUnlock 0`, `MaxDuration 500` |
| `roblox/ServerStorage/Modes/Obby/Server/*.lua` | `ServerStorage.Modes.Obby.Server.*` (ModuleScripts) | His server code, cloned fresh as `Modes.Obby.Runtime` each round: RunControl, BlockSync, SkyArm, ArmMirror, HazardManager, ActiveBayTracker, BridgeFeed, DebugMode (the solo crate source), Status (new: the always-on half of his DebugMenu), DebugMenu and GhostMode (debug only), BayData, CrateDefs, Mapping |
| `roblox/ReplicatedStorage/Obby/Config.lua` | `ReplicatedStorage.Obby.Config` | His tunables, plus `OriginZ = 1100`, `ArcadeDebug = false`, `RunnerScale = 1`, `ArcadeScale = 1.5`, `ResultSeconds`, `RespawnSettleSeconds`, `Dark*` |
| (made by Module and the installer) | `ReplicatedStorage.Obby.Remotes` | His 9 remotes (`DebugStatus` is renamed `Status`) |
| `roblox/ReplicatedStorage/Obby/Views/PlayerView.lua`, `RobotView.lua` | `ReplicatedStorage.Obby.Views.*` | Role views. RobotView is OverseerCam, always on, with the objective panel and run/link status |
| `roblox/ReplicatedStorage/Obby/Views/Player/*.client.lua` | `...Views.Player.*` (LocalScripts) | ObjectiveHud (plus a run clock), CellEditor (solo only), BackdropFx, CameraPolish, DarkRoom (new) |
| `roblox/ReplicatedStorage/Obby/Views/Debug/*.client.lua` | `...Views.Debug.*` | DebugMenu (F1/F2) and GhostControl (Q), cloned only when ArcadeDebug is on |
| `roblox/ReplicatedStorage/Core/Games/Obby.lua` | `ReplicatedStorage.Core.Games.Obby` | Registry entry. `ArcadeActiveGame` makes it active while the Obby bay runs, so the core needed no edit |
| `roblox/tools/prepare_obby_map.lua` | (command bar, in Place1) | Packs the map |
| `roblox/tools/install_obby_mode.lua` | (command bar, in the arcade) | **Generated** by `roblox/tools/build_install_obby.py` (re-run it after any change). Embeds every script and module, makes the remotes, keeps and checks the Map, the cabinet and leftover standalone scripts |

How the contract is met:

- **Fresh per round.** Start clones `Server/` and requires the clone. Engine, remote and player connections go
  through `session.track`, and threads through `session.spawn`. Loops are `while folder.Parent` or check `session.alive`.
- **Scoped to the round.** HUDs, loops and remotes reach `session.runners` and the robot role only. No `FireAllClients`
  or `Players:GetPlayers()` is left in the game logic.
- **No own robot link.** The obby's `Bridge` is gone. BridgeFeed reads `Core.StateStore` (hello and the raw mm frame) on
  `Shared.StateStore.Updated`, and the feed is `live` when `Shared.Bridge.isOnline()` at Start, else `solo`.
- **No Lighting.** The dark room sets `Dark` on `Bay04`, and the runner's camera gets a ColorCorrectionEffect.
- **No spawn lookups.** `RunControl.startCFrame()` reads `Map.Start`.
- **Debug off by default.** Every debug key (F1, F2, Q, the cell editor's 1–9/N/R/T/K/H/M, HazardManager's R) and
  every DebugCommand need `ArcadeDebug`. Set it with `Config.ArcadeDebug` or the attribute `ArcadeDebug = true` on
  `ServerStorage.Modes.Obby`.

The rules of a round:

- **Win:** a runner reaches `Map.Finish` (course Z 115..123, past bay 4's exit) with bay 4 solved, before the
  480 s clock runs out.
- **Results:** when everyone has finished or gone, or the clock hits 0, a 4 s result screen shows, then `Finished`
  fires once in list form.
- **Death:** the runner respawns at the approach to the furthest bay they reached. That bay is rebuilt fresh, unless
  another runner is standing in it.
- **Runner size:** runners play at 1.0 (the size the course was built for), not the arcade's 1.5×. Start shrinks
  them, every respawn is shrunk again, and a 0.25 s check catches CharacterScale growing a new character late (it
  waits for the avatar to load). Stop and PlayerLeft give them 1.5 back. ScaleTo keeps the feet on the floor and
  restores StarterPlayer's walk speed and jump height.
- **Lobby pad and IsDecided:** `Map.LobbyPad` is Enabled from Start until the runner enters bay 1, and again from the
  moment the round is decided. `Mode.IsDecided()` is true once a runner has finished or the clock ran out (or the round
  is over). The arcade asks it before a pad, so a decided player keeps their result: a finish is a win, anything else
  a loss. When the last runner leaves, `Finished` fires at once (the arcade only waits a moment).

### Getting the map in

1. In the repo root: `python -m http.server 8771 --bind 127.0.0.1` (not 8765, which is the robot bridge's port).
2. Open `lebot_obby/Place1.rbxl` in Studio, Edit mode, and run this in the command bar:
   ```lua
   game:GetService("HttpService").HttpEnabled = true
   loadstring(game:GetService("HttpService"):GetAsync("http://127.0.0.1:8771/roblox/tools/prepare_obby_map.lua"))()
   ```
   This moves `Warehouse`, `Backdrop` and `StartSpawn` into one Model, `Workspace.Map`. It turns the SpawnLocation into a
   plain part and adds `Start`, `Finish` and `LobbyPad` (tagged `LobbyTeleporter`). It then shifts the whole Model
   +1100 Z (to about Z 1033..1287, X −87..119) and sets it Persistent. Check the bounds line in Output.
3. Right click `Workspace.Map` → **Save to File…** → `places/ObbyMap.rbxm`. Close Place1 **without saving**.
   `*.rbxm` is gitignored, so use `git add -f` if you want it in the repo.
4. Open `places/LeBot_Arcade.rbxl`. Right click `ServerStorage.Modes.Obby` (make the Folder if it isn't there) →
   **Insert from File…** → `places/ObbyMap.rbxm`. It arrives as `Map`.
5. In the arcade, run `roblox/tools/install_obby_mode.lua` in Edit mode. Either paste it into the command bar or the
   Studio MCP's execute_luau, or, with the HTTP server from step 1 running, run this in the command bar:
   ```lua
   loadstring(game:GetService("HttpService"):GetAsync("http://127.0.0.1:8771/roblox/tools/install_obby_mode.lua"))()
   ```
   It's generated: after changing any obby file, run `python roblox/tools/build_install_obby.py` first.
   Fix every warning it prints. It checks for the Map's parts, a SpawnLocation or script in the map, Cell_0_0 at
   Z ≈ 1104, the Obby cabinet in `Workshop.Bays` (Mode `Obby`), the core Bridge, and standalone copies of obby scripts.
   Then save the arcade place.
6. Play. Walk into the Obby portal alone (solo: the grid places the blocks), then with the mock bridge (live).

### Unsure, check these first

- **1.5× (resolved by running at 1.0).** The notes below are what 1.5× would have done; runners are now 1.0 for the
  round. What's left to check is the scale switch itself: a runner grown back late by CharacterScale shows 1.5× for up to
  0.25 s before the check shrinks them.
- **1.5× saw-wall levers.** The level gate holds: it raycasts 9 studs down from the root and compares the *support's*
  height to the lever's stand level (±3.02). So a lever still can't be thrown one level too low. What changes:
  - One level too low, the hold prompt now shows from about 7.7 studs away instead of 6.6, then gets refused.
  - The single centre ray can miss a crate edge the wider body is still standing on, which reads as "NEED 1 CRATE".
  - Lever B headroom: on the 2-stack, the head reaches about 21.2. The right rail beam sits at X 28, Y 18, directly over
    cell (3,0). Check whether it's collidable and blocks the jump.
- **1.5× laser walk (the bigger risk).** Death is any touch on a live pad or beam (beams at Y 1.6, 4.4 and 7.2).
  - At 1.5× the arms reach about ±3, so drifting **about 1.1 studs** off a cell's centre line puts an arm into a live
    neighbour's 4.4 beam. At 1× that took 2.1.
  - The 7.2 beam is now at head height.
  - If playtests confirm it, the fix is a per-player opt-out in `CharacterScale` (e.g. a `NoScale` attribute Module
    sets on runners) or thinner/shorter beams. Neither is done.
- **Dark room look.** The tint values (`Config.Dark*`) are a guess. Tune them by eye: the sconces must still read and
  the screws must only show when lit.
- **Hall lighting.** Kushagra's Atmosphere, Bloom, `BackdropGrade` and Sky don't come over (the arcade owns
  Lighting), so the hall looks different from Place1. The course still gets light from the skylight strip.
- **Respawn rebuilds the bay.** That clears its crates. In live they re-seat from the real mat on the next frame; in
  solo the runner places them again.
- **Robot objective after joining mid-bay.** The robot sees the objective on the next push (most bays re-push every
  0.2 s). Status is answered on request; the objective isn't.
- **Live mode:** never run against hardware (robot-link.md). If `live` starts before the core has a hello, Mapping keeps
  its defaults.
- **Python side:** the arcade sends `{t = "mode", name = "obby"}` and needs a mapping for it.
- **Known in Kushagra's code, left alone:** the saw's `placeWall` puts both blade rows at the same height.
  `characterFrom` can kill any character in the map, but only runners are ever in it.
- **More than one runner:** bays seal behind the first runner. Roles normally give one character, so this hasn't been
  designed around.
