-- StarterPlayer.StarterPlayerScripts.RoleClient
-- Shows this client the view for its role (Player attribute "Role") and the active game
-- (Core.GameRegistry), and switches cleanly when either changes: exit() the old view, enter() the new one.
-- Also, per role:
--   player     the normal camera; sends its camera to the spectators (Core.Remotes.ViewSync)
--   robot      a fully scripted camera (the robot views drive it); no character
--   spectator  the player's camera, eased toward each ViewSync sample; read only (views get readOnly)
-- F8 (Core.Config.roleSwapKey) asks the server to swap the player and robot roles (Studio only).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Core = ReplicatedStorage:WaitForChild("Core")
local Roles = require(Core:WaitForChild("Roles"))
local GameRegistry = require(Core:WaitForChild("GameRegistry"))
local Config = require(Core:WaitForChild("Config"))
local remotes = Core:WaitForChild("Remotes")
local roleSwap = remotes:WaitForChild("RoleSwap")
local viewSync = remotes:WaitForChild("ViewSync")

local SPECTATE_SMOOTHING = 15 -- per second

local localPlayer = Players.LocalPlayer

local current = { module = nil, role = nil, view = nil }

local function switchOnce()
	local role = Roles.of(localPlayer)
	local activeId = GameRegistry.active()
	local module = GameRegistry.viewFor(role, GameRegistry.get(activeId), GameRegistry.lobbyEntry())
	if module == current.module and role == current.role then
		return
	end
	if current.view and current.view.exit then
		local ok, err = pcall(current.view.exit)
		if not ok then
			warn("[RoleClient] exit failed: " .. tostring(err))
		end
	end
	current.module, current.role, current.view = module, role, nil

	local camera = workspace.CurrentCamera
	if role == Roles.PLAYER then
		camera.CameraType = Enum.CameraType.Custom
		local humanoid = localPlayer.Character and localPlayer.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	elseif role ~= nil then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	if module then
		local ok, view = pcall(require, module)
		if not ok then
			warn("[RoleClient] " .. module:GetFullName() .. " failed to load: " .. tostring(view))
			return
		end
		current.view = view
		local entered, err = pcall(view.enter, { role = role, readOnly = role == Roles.SPECTATOR, game = activeId })
		if not entered then
			warn("[RoleClient] " .. module:GetFullName() .. " enter failed: " .. tostring(err))
		end
	end
	print(string.format("[RoleClient] %s, game %s: %s", tostring(role), tostring(activeId), module and module.Name or "no view"))
end

-- One switch at a time: exit() may yield a frame, and a role and a game change can land together.
local busy, again = false, false
local function switch()
	if busy then
		again = true
		return
	end
	busy = true
	repeat
		again = false
		switchOnce()
	until not again
	busy = false
end

localPlayer:GetAttributeChangedSignal(Roles.ATTRIBUTE):Connect(switch)
GameRegistry.activeChanged():Connect(switch)
localPlayer.CharacterAdded:Connect(function(character)
	if Roles.of(localPlayer) == Roles.PLAYER then
		workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
		workspace.CurrentCamera.CameraSubject = character:WaitForChild("Humanoid", 10)
	end
end)
switch()

UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Config.roleSwapKey and not UserInputService:GetFocusedTextBox() then
		roleSwap:FireServer()
	end
end)

-- The player's camera, for the spectators.
local sentAt = 0
RunService.Heartbeat:Connect(function()
	if Roles.of(localPlayer) ~= Roles.PLAYER or os.clock() - sentAt < 1 / Config.viewSyncHz then
		return
	end
	sentAt = os.clock()
	local camera = workspace.CurrentCamera
	viewSync:FireServer(camera.CFrame, camera.FieldOfView)
end)

-- Spectators: follow it.
local target, targetFov = nil, nil
viewSync.OnClientEvent:Connect(function(cframe, fov)
	target, targetFov = cframe, fov
end)
RunService:BindToRenderStep("SpectatePlayer", Enum.RenderPriority.Camera.Value, function(dt)
	if Roles.of(localPlayer) ~= Roles.SPECTATOR or target == nil then
		return
	end
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local k = 1 - math.exp(-SPECTATE_SMOOTHING * dt)
	camera.CFrame = camera.CFrame:Lerp(target, k)
	camera.FieldOfView += (targetFov - camera.FieldOfView) * k
end)
