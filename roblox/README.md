# Roblox source mirror

Roblox saves places as binary `.rbxl` files that don't diff or merge, so the place file
itself is gitignored. This folder is the **text mirror** of every Luau script in the place,
kept so the game logic is reviewable in git (and visible to judges reading the repo).

One person owns the place file. When a script changes in Studio, mirror it here.

## Where each file lives in the place

| Repo path | Studio location | Kind |
|---|---|---|
| `ReplicatedStorage/Config.lua` | `ReplicatedStorage.Config` | ModuleScript |
| `ReplicatedStorage/CrateDefs.lua` | `ReplicatedStorage.CrateDefs` | ModuleScript |
| `ReplicatedStorage/BayData.lua` | `ReplicatedStorage.BayData` | ModuleScript |
| `ServerScriptService/BlockSync.lua` | `ServerScriptService.BlockSync` | ModuleScript |
| `ServerScriptService/SkyArm.lua` | `ServerScriptService.SkyArm` | ModuleScript |
| `ServerScriptService/HazardManager.lua` | `ServerScriptService.HazardManager` | Script |
| `ServerScriptService/DebugMode.lua` | `ServerScriptService.DebugMode` | Script |
| `ServerScriptService/GhostMode.lua` | `ServerScriptService.GhostMode` | Script |
| `StarterPlayerScripts/DebugCellEditor.client.lua` | `StarterPlayer.StarterPlayerScripts.DebugCellEditor` | LocalScript |
| `StarterPlayerScripts/GhostControl.client.lua` | `StarterPlayer.StarterPlayerScripts.GhostControl` | LocalScript |

`ReplicatedStorage.Remotes` holds RemoteEvents (`CellEdit`, `CellsUpdated`, `DebugHotkey`,
`GhostToggle`) and has no source of its own.

## World geometry

The warehouse shell, the nine bay prefabs and the catwalks are **generated**, not hand-placed.
The generator scripts live in `build/` and are run once from Studio's command bar in Edit mode.
