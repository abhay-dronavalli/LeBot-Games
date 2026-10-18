-- ServerScriptService.CoreRoles
-- Assigns roles (Core.Roles): the first client to join is the player, the second the robot, everyone after
-- a spectator; a freed role goes to the next client to join. The role is the Player attribute "Role".
-- Characters are managed here, not by CharacterAutoLoads: only the player role has one (respawned after
-- a death); the robot and spectators have none.
-- Remotes in ReplicatedStorage.Core.Remotes:
--   RoleSwap (RemoteEvent, any client -> server, Studio only): the player and robot trade roles (F8)
--   ViewSync (UnreliableRemoteEvent): the player's camera -> server -> every spectator
-- Core.Config.debugForceRole gives the first client a fixed role for solo Play testing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Core = ReplicatedStorage:WaitForChild("Core")
local Roles = require(Core:WaitForChild("Roles"))
local Config = require(Core:WaitForChild("Config"))

Players.CharacterAutoLoads = false

local function getOrCreate(parent, className, name)
	local child = parent:FindFirstChild(name)
	if not child then
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end

local remotes = getOrCreate(Core, "Folder", "Remotes")
local roleSwap = getOrCreate(remotes, "RemoteEvent", "RoleSwap")
local viewSync = getOrCreate(remotes, "UnreliableRemoteEvent", "ViewSync")

local assigner = Roles.Assigner.new({ forced = Config.debugForceRole })

-- With StreamingEnabled a client streams the world around its character, so a client with none (the
-- robot, spectators) would get almost nothing. They stream around this anchor instead: an invisible part
-- at the room's center (Core.Config.lobbyOrbit.center).
local focus = workspace:FindFirstChild("RoleStreamFocus")
if not focus then
	focus = Instance.new("Part")
	focus.Name = "RoleStreamFocus"
	focus.Anchored, focus.CanCollide, focus.CanQuery, focus.CanTouch = true, false, false, false
	focus.Transparency = 1
	focus.Size = Vector3.one
	focus.Position = Config.lobbyOrbit.center
	focus.Parent = workspace
end

-- Gives the player role a character and takes it away from everyone else.
local function applyCharacter(player)
	if Roles.of(player) == Roles.PLAYER then
		player.ReplicationFocus = nil -- streams around its character
		if player.Character == nil then
			player:LoadCharacter()
		end
	else
		player.ReplicationFocus = focus
		if player.Character then
			player.Character:Destroy()
			player.Character = nil
		end
	end
end

local function watchDeaths(player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		humanoid.Died:Connect(function()
			task.delay(Players.RespawnTime, function()
				if player.Parent and player.Character == character and Roles.of(player) == Roles.PLAYER then
					player:LoadCharacter()
				end
			end)
		end)
	end)
end

local function onJoin(player)
	local role = assigner:join(player)
	print(string.format("[CoreRoles] %s joined as %s", player.Name, role))
	watchDeaths(player)
	applyCharacter(player)
end

Players.PlayerAdded:Connect(onJoin)
for _, player in ipairs(Players:GetPlayers()) do
	if assigner:roleOf(player) == nil then
		task.spawn(onJoin, player)
	end
end

Players.PlayerRemoving:Connect(function(player)
	print(string.format("[CoreRoles] %s (%s) left", player.Name, tostring(assigner:roleOf(player))))
	assigner:leave(player)
end)

roleSwap.OnServerEvent:Connect(function(player)
	if not RunService:IsStudio() then
		return -- a debug override; never in a live server
	end
	local changed = assigner:swap()
	print(string.format("[CoreRoles] roles swapped by %s: player %s, robot %s", player.Name,
		tostring(assigner:holder(Roles.PLAYER) and assigner:holder(Roles.PLAYER).Name),
		tostring(assigner:holder(Roles.ROBOT) and assigner:holder(Roles.ROBOT).Name)))
	for _, p in ipairs(changed) do
		applyCharacter(p)
	end
end)

viewSync.OnServerEvent:Connect(function(player, cframe, fov)
	if Roles.of(player) ~= Roles.PLAYER or typeof(cframe) ~= "CFrame" or type(fov) ~= "number" then
		return
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if Roles.of(p) == Roles.SPECTATOR then
			viewSync:FireClient(p, cframe, fov)
		end
	end
end)
