# Roles and the game registry

Every game in this place is played by two people: a **player** at the Roblox screen and a **robot**, the operator at the real SO-101 arm. Anyone else who joins is a **spectator**. This is core code (`ReplicatedStorage.Core`), shared by every game. A game plugs in by registering a **PlayerView** and a **RobotView**.

## Roles

| Role | Who | Character | Camera | Sends game input |
|---|---|---|---|---|
| `player` | first client to join | yes | normal | yes, the only role that can |
| `robot` | second client | none | fully scripted by the robot views | no |
| `spectator` | everyone after | none | follows the player's camera | no (read only) |

- **Assignment** (`ServerScriptService.CoreRoles`, logic in `Core.Roles.Assigner`): each client gets the first free role in the order player, robot, else spectator. When someone leaves, their role is empty until the **next client to join** fills it; spectators are not promoted.
- **Where it lives:** the role is the `Role` attribute on the `Player` object (`"player"`, `"robot"`, `"spectator"`). Clients read it with `Roles.of(player)` or `player:GetAttribute("Role")`.
- **Characters:** `Players.CharacterAutoLoads` is off. CoreRoles calls `LoadCharacter` for the player role only, and again after a death. The robot and spectators have no character.
  - With `StreamingEnabled`, a client with no character would stream almost nothing. Their `ReplicationFocus` is `Workspace.RoleStreamFocus`, an invisible part at the room's center that CoreRoles creates.
- **Spectators:** the player's client sends its camera to the server 20 times a second (`Core.Remotes.ViewSync`). The server relays it to spectators only, and their camera eases toward it.
  - Spectators get the game's PlayerView with `readOnly = true`, so their copy sends nothing to the server.
  - Useful for a projector.
- **Debug:**
  - **F8** in any window swaps the player and robot roles (`Core.Remotes.RoleSwap`). This works in Studio only.
  - `Core.Config.debugForceRole = "player"` or `"robot"` gives the first client that role, for solo Play testing. With `"robot"`, a second client becomes the player.
  - Reset it to `nil` before committing.

### Guard every remote that changes game state

A robot or spectator client must never be able to change the game. Wrap every server handler that does (start, mode pick, moves, clicks) with `Roles.guard`. It drops (and logs) calls from anyone who isn't the player role:

```lua
local Roles = require(ReplicatedStorage.Core.Roles)

pickRemote.OnServerEvent:Connect(Roles.guard(function(player, choice)
	myGame:pick(player, choice)
end, "MyGamePick"))

prompt.Triggered:Connect(Roles.guard(function(player)
	myGame:start(player)
end, "Play My Game"))
```

Read-only requests (for example "send me the current state") don't need the guard.

## Game registry

`Core.GameRegistry` knows the games in the place and which one is **active**: the one the player is in now.

### Register a game

Add a ModuleScript to `ReplicatedStorage.Core.Games` that returns the game's entry:

```lua
-- ReplicatedStorage.Core.Games.MyObby
local views = game:GetService("ReplicatedStorage"):WaitForChild("MyObby"):WaitForChild("Views")

return {
	id = "MyObby",                          -- unique; what setActive uses
	name = "My Obby",                       -- display name
	playerView = views:WaitForChild("PlayerView"), -- ModuleScripts, see below
	robotView = views:WaitForChild("RobotView"),
	-- lobby = true,                        -- only if this game's PlayerView is also the lobby's
}
```

`GameRegistry.register(entry)` adds one from code too. Pattern Match is `Core.Games.PatternMatch`. It sets `lobby = true` because this place's lobby is the Pattern Match room.

### Mark the game active

The game's server code sets the active game when the player starts it and clears it when it is over:

```lua
local GameRegistry = require(ReplicatedStorage.Core.GameRegistry)
GameRegistry.setActive("MyObby")  -- the player started it
GameRegistry.setActive(nil)       -- back to the lobby
```

It is the `ActiveGame` attribute on `ReplicatedStorage.Core`, so every client can read it (`GameRegistry.active()`, `GameRegistry.activeChanged()`).

### Which view each client shows

`StarterPlayerScripts.RoleClient` shows each client the view for its role and the active game. When either changes, it calls the old view's `exit()` and then the new view's `enter(ctx)`. One switch runs at a time.

| Role | Active game | View |
|---|---|---|
| robot | none (lobby) | `Core.Views.LobbyRobotView`: slow orbit over the room, "ROBOT STATION", "Waiting for your partner to pick a game", and the robot link badge (ROBOT LIVE / MOCK / OFFLINE / NO ROBOT, from the `RobotLink` attribute on `Core`) |
| robot | a game | that game's `robotView` |
| player, spectator | none | the lobby game's `playerView` (the entry with `lobby = true`), or nothing |
| player, spectator | a game | that game's `playerView` |

`ctx` is `{ role = "player" | "robot" | "spectator", readOnly = (role == "spectator"), game = activeId }`.

## Writing the views

A view is a ModuleScript returning `enter(ctx)` and `exit()`. It runs on the client. `exit()` must undo everything `enter()` did: GUIs, connections, camera, lighting. The next view starts from a clean screen. `enter()` may be called again after an `exit()`.

### RobotView template

The operator is at the real arm, looking at the screen only between moves. Show what they need in order to act: the timer, the score, what their partner is doing. **Don't show anything the game wants them not to know** (for Pattern Match: the boards and the target). Point the scripted camera away from anything secret. If the robot needs game data, send it a filtered payload on its own remote instead of the full one (Pattern Match: `Game.robotPayload` on `RobotUI`).

```lua
-- ReplicatedStorage.MyObby.Views.RobotView
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RobotView = {}
local gui, connections = nil, {}

function RobotView.enter(ctx)
	RobotView.exit()
	gui = Instance.new("ScreenGui")
	gui.Name = "MyObbyRobot"
	gui.ResetOnSpawn = false              -- the robot has no character, but keep views independent of spawns
	gui.IgnoreGuiInset = true
	local title = Instance.new("TextLabel")
	title.Size = UDim2.fromScale(1, 0.2)
	title.Text = "MY OBBY - you're the robot"
	title.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	table.insert(connections, RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable -- set every frame: nothing else may move it
		camera.CFrame = CFrame.lookAt(Vector3.new(0, 20, 40), Vector3.new(0, 5, 0))
	end))
end

function RobotView.exit()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if gui then
		gui:Destroy()
		gui = nil
	end
end

return RobotView
```

### PlayerView template

The simplest PlayerView clones the game's existing ScreenGuis (kept as templates outside StarterGui, where they don't run) into PlayerGui on `enter` and destroys them on `exit`. That is what Pattern Match does (`PatternMatch.Views.PlayerView`, templates in `Views.Player`).

- **Read only:** mark copies for spectators with `readOnly`, and make their scripts skip every `FireServer` that changes the game.
- **Exit in two steps:** first give the scripts a frame to clean up while they're still running, by setting an attribute they listen to. A script's own `Destroying` handler isn't reliable once the script itself is being destroyed.

```lua
-- ReplicatedStorage.MyObby.Views.PlayerView
local Players = game:GetService("Players")

local templates = script.Parent:WaitForChild("Player") -- ScreenGuis / Folders with LocalScripts
local PlayerView = {}
local live = {}

function PlayerView.enter(ctx)
	PlayerView.exit()
	for _, template in ipairs(templates:GetChildren()) do
		local copy = template:Clone()
		copy:SetAttribute("ReadOnly", ctx.readOnly)  -- scripts: if ReadOnly, never FireServer game input
		copy.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		table.insert(live, copy)
	end
end

function PlayerView.exit()
	if #live == 0 then
		return
	end
	for _, copy in ipairs(live) do
		copy:SetAttribute("Exiting", true)  -- scripts: restore the camera, stop effects
	end
	task.wait()
	for _, copy in ipairs(live) do
		copy:Destroy()
	end
	table.clear(live)
end

return PlayerView
```

Inside a template script:

```lua
local screen = script.Parent
local readOnly = screen:GetAttribute("ReadOnly") == true
screen:GetAttributeChangedSignal("Exiting"):Connect(function()
	workspace.CurrentCamera.CameraType = Enum.CameraType.Custom -- whatever this script changed
end)
```

## Testing with two players

1. Test tab → Clients and Servers → 2 players → Start. The first client window is the player, the second the robot.
2. **F8** in either window swaps them.
3. Solo: set `Core.Config.debugForceRole`. To start a game without a player (solo robot), Pattern Match has a server-side hook: `ReplicatedStorage.PatternMatch.Debug:Fire({ op = "start", mode = "easy" })`; `{ op = "endShift" }` ends it.
