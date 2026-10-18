# Obby as an arcade mode: conversion plan

Oct 18, 2026. Plan only. Nothing here is built yet. Run it once Kushagra freezes his design work.
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
