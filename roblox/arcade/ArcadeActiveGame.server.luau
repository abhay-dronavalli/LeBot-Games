-- Studio location: ServerScriptService.ArcadeActiveGame (Script)
-- Tells the roles core (ReplicatedStorage.Core.GameRegistry) which game is running, for arcade modes that
-- don't do it themselves, so RoleClient shows the robot that game's robot view.
-- ArcadeManager sets the ReplicatedStorage.Arcade attribute "ActiveMode" to the bay's name while a game
-- runs and to "" after. The bay folder (Workspace.Workshop.Bays.<bay>) names its mode in its "Mode"
-- attribute ("Flood"); GAME_FOR_MODE maps a mode to its registry id when the two differ (default: same).
--   game starts: if the id is registered (a ModuleScript in ReplicatedStorage.Core.Games), isn't in
--                SELF_MANAGED and no other game is already active -> GameRegistry.setActive(id)
--   game ends:   clears the active game, only if it is still the one set here
-- Modes in SELF_MANAGED call GameRegistry.setActive in their own Start / Stop and are left alone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameRegistry = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("GameRegistry"))
local arcade = ReplicatedStorage:WaitForChild("Arcade")
local bays = workspace:WaitForChild("Workshop"):WaitForChild("Bays")

local SELF_MANAGED = { PatternMatch = true, Arena = true }
local GAME_FOR_MODE = {} -- e.g. { RedLight = "RedLightGreenLight" }

local ours = nil -- the id this script set active, or nil

local function gameFor(bayName)
	if bayName == nil or bayName == "" then
		return nil
	end
	local bay = bays:FindFirstChild(bayName)
	local mode = bay and bay:GetAttribute("Mode") or bayName
	local id = GAME_FOR_MODE[mode] or mode
	if SELF_MANAGED[id] or GameRegistry.get(id) == nil then
		return nil -- manages itself, or has no roles views: the robot keeps the lobby view
	end
	return id
end

local function onActiveMode()
	local bayName = arcade:GetAttribute("ActiveMode")
	local id = gameFor(bayName)
	if ours and ours ~= id then
		if GameRegistry.active() == ours then
			GameRegistry.setActive(nil)
		end
		ours = nil
	end
	if id and id ~= ours then
		local current = GameRegistry.active()
		if current ~= nil and current ~= id then
			warn(string.format("[ArcadeActiveGame] %s started while %s is active; leaving it", id, current))
			return
		end
		ours = id
		GameRegistry.setActive(id)
		print(string.format("[ArcadeActiveGame] %s -> active game %s", tostring(bayName), id))
	end
end

arcade:GetAttributeChangedSignal("ActiveMode"):Connect(onActiveMode)
onActiveMode()
