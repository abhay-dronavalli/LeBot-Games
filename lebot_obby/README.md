# Roblox source mirror

Roblox saves places as binary `.rbxl` files that don't diff or merge, so the place file
itself is gitignored. This folder is the **text mirror** of every Luau script in the place,
kept so the game logic is reviewable in git (and visible to judges reading the repo).

One person owns the place file. When a script changes in Studio, mirror it here.

## Mirroring without transcription drift

Retyping a script between Studio and git drifts silently, which is why this file used to say
"verify with a checksum". `tools/studio_sync.py` removes the transcription step instead of
guarding it:

```
python tools/studio_sync.py 8767        # serves ./src, GET pulls into Studio, POST writes back
```

Then from Studio's command bar (or an `execute_luau` call), with HTTP requests enabled:

```lua
-- disk -> Studio
script.Source = game:GetService("HttpService"):GetAsync("http://127.0.0.1:8767/Mapping.lua")
-- Studio -> disk; the reply is "<length> <bytesum>" to compare against the file
game:GetService("HttpService"):PostAsync("http://127.0.0.1:8767/Mapping.lua", script.Source,
	Enum.HttpContentType.TextPlain)
```

The bytes that leave one side are the bytes that land on the other, and both ends report
length and byte sum so the match is proven rather than assumed.

## Where each file lives in the place

| Repo path | Studio location | Kind |
|---|---|---|
| `ReplicatedStorage/Config.lua` | `ReplicatedStorage.Config` | ModuleScript |
| `ReplicatedStorage/CrateDefs.lua` | `ReplicatedStorage.CrateDefs` | ModuleScript |
| `ReplicatedStorage/BayData.lua` | `ReplicatedStorage.BayData` | ModuleScript |
| `ReplicatedStorage/Mapping.lua` | `ReplicatedStorage.Mapping` | ModuleScript |
| `ReplicatedStorage/UiTheme.lua` | `ReplicatedStorage.UiTheme` | ModuleScript |
| `ServerScriptService/RunControl.lua` | `ServerScriptService.RunControl` | ModuleScript |
| `ServerScriptService/ActiveBayTracker.lua` | `ServerScriptService.ActiveBayTracker` | Script |
| `ServerScriptService/DebugMenu.lua` | `ServerScriptService.DebugMenu` | Script |
| `ServerScriptService/BlockSync.lua` | `ServerScriptService.BlockSync` | ModuleScript |
| `ServerScriptService/SkyArm.lua` | `ServerScriptService.SkyArm` | ModuleScript |
| `ServerScriptService/Bridge.lua` | `ServerScriptService.Bridge` | ModuleScript |
| `ServerScriptService/ArmMirror.lua` | `ServerScriptService.ArmMirror` | ModuleScript |
| `ServerScriptService/BridgeProbe.lua` | `ServerScriptService.BridgeProbe` | Script |
| `ServerScriptService/HazardManager.lua` | `ServerScriptService.HazardManager` | Script |
| `ServerScriptService/DebugMode.lua` | `ServerScriptService.DebugMode` | Script |
| `ServerScriptService/GhostMode.lua` | `ServerScriptService.GhostMode` | Script |
| `StarterPlayerScripts/DebugMenu.client.lua` | `StarterPlayer.StarterPlayerScripts.DebugMenu` | LocalScript |
| `StarterPlayerScripts/OverseerCam.client.lua` | `StarterPlayer.StarterPlayerScripts.OverseerCam` | LocalScript |
| `StarterPlayerScripts/CameraPolish.client.lua` | `StarterPlayer.StarterPlayerScripts.CameraPolish` | LocalScript |
| `StarterPlayerScripts/BackdropFx.client.lua` | `StarterPlayer.StarterPlayerScripts.BackdropFx` | LocalScript |
| `StarterPlayerScripts/DebugCellEditor.client.lua` | `StarterPlayer.StarterPlayerScripts.DebugCellEditor` | LocalScript |
| `StarterPlayerScripts/GhostControl.client.lua` | `StarterPlayer.StarterPlayerScripts.GhostControl` | LocalScript |
| `StarterPlayerScripts/ObjectiveHud.client.lua` | `StarterPlayer.StarterPlayerScripts.ObjectiveHud` | LocalScript |

`ReplicatedStorage.Remotes` holds RemoteEvents (`CellEdit`, `CellsUpdated`, `DebugHotkey`,
`GhostToggle`, `Objective`, `DebugCommand`, `DebugStatus`, `BayCells`, `CameraFace`, `Toast`) and has no
source of its own.

`CameraFace` carries a look direction to one client whenever the server moves that player, so
the camera turns with the body. Writing `HumanoidRootPart.CFrame` turns the character but not
the view -- the camera's yaw lives in the client's camera module and nothing on the server can
reach it, which is why every scenario jump used to leave you facing the way you came.

`Toast` is the popup channel: `FireClient(player, text, tone, big)`. `ObjectiveHud` raises it as
a transient toast, or as a full-screen stamp when `big` is set. See
[`obby_planmds/ui.md`](../obby_planmds/ui.md).

`Objective` is the on-screen task channel: an obstacle fires it with
`{title, task, hint, tone, timer, timerLabel, timerTone, flash}` whenever its state changes,
and with `nil` to clear the HUD. It's deliberately generic rather than saw-wall specific, so
the other bays can drive the same HUD as they get built.

## Rebuilding geometry from Config

`build/fit_shell.lua` resizes the shell walls and roof trusses to match `Config.WallHeight`.
Run it from the command bar in **Edit** mode (geometry changed during a playtest is discarded):

```lua
loadstring(game:GetService("HttpService")
    :GetAsync("http://127.0.0.1:8767/fit_shell.lua"))()   -- or pass a height: (...)(60)
```

It **fits** rather than rebuilds -- resizing the parts that are already there, keeping their
materials and names -- so it is idempotent and cannot lose detail that exists only in the
place file. It deliberately does not move the rail beams: they sit at `Config.GantryHeight`,
and SkyArm's reach is measured down from there, so raising the roof is free but raising the
rails stops the arm touching the floor.

## World geometry

**This is no longer lost.** The warehouse shell, bay prefabs, catwalks, pallet racks and sky
rails were originally generated by one-off command-bar scripts that were not kept, and for a
while that geometry existed only inside the `.rbxl`. The environment has since been extracted
into idempotent generators under [`build/`](../build/):

| Script | What it produces |
|---|---|
| `fit_shell.lua` | Resizes the shell walls and roof trusses to `Config.WallHeight` |
| `scope_course.lua` | Parks/restores bays past `Config.NumBays` in `ServerStorage.OutOfScope` |
| `backdrop_lighting.lua` | Lighting, Atmosphere, Bloom, colour grade, and the Dark Room's restore baseline |
| `backdrop_hall.lua` | The industrial hall: floor, walls, windows, roof, skylight, gas lamps |
| `backdrop_containment.lua` | Shell to invisible collider, platform decks and skirt, spawn, pallet racks |
| `backdrop_props.lua` | Fences, pipe runs, machinery, labs, per-bay dressing, catwalk restyle |

Each deletes and recreates only its own sub-folder of `Workspace.Backdrop`, so they are safe to
re-run in any order. Run them from the command bar in **Edit** mode; see
[`obby_planmds/environment.md`](../obby_planmds/environment.md) for the full design, the folder
layout, the CollectionService tags and the exact commands.

What is still baked into the `.rbxl` and has no generator: the **nine bay prefabs** themselves
(floors, `Cell_c_r` anchors, borders, exit doors, signs), the catwalk and pallet-rack geometry,
and the sky rails. Two consequences remain:

- Changing a layout value in `Config.lua` will **not** move the baked bays. Only code that
  reads `Config` at runtime (`HazardManager`, `SkyArm`, `BlockSync`) follows it.
- `BlockSync.cellToWorld` deliberately reads the `Cell_c_r` anchor parts rather than
  recomputing positions, so the baked geometry stays the single source of truth for where a
  crate actually goes. **Never move, resize or rename an anchor.**

## Reference

`BROKER-2-so-101-teleop-arm-2.3mf` in the repo root is the printable SO-101 teleop arm. The
link lengths in `SkyArm.lua` (`L1 = 6.2`, `L2 = 5.69`) come from measuring `Upper_arm_SO101`
and `Under_arm_SO101` in that model, so the in-game arm has the real robot's proportions.
