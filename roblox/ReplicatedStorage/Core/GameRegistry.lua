-- ReplicatedStorage.Core.GameRegistry
-- The games in this place and which one is active (docs/roles.md).
-- A game registers itself with a ModuleScript in ReplicatedStorage.Core.Games returning its entry:
--   { id = "PatternMatch", name = "Pattern Match",
--     playerView = <ModuleScript>, robotView = <ModuleScript>,   -- each returns { enter(ctx), exit() }
--     lobby = true }                                             -- optional: its PlayerView is also the
--                                                                --   lobby's (at most one game)
-- (GameRegistry.register(entry) adds one at runtime too.) The active game is the one the player is in:
-- the game's server code calls setActive(id) when it starts and setActive(nil) when it ends, and it is
-- the "ActiveGame" attribute on ReplicatedStorage.Core, so every client can read it.
-- Each client (StarterPlayerScripts.RoleClient) shows viewFor(its role, active entry, lobby entry):
--   robot             the active game's robotView, or Core.Views.LobbyRobotView in the lobby
--   player/spectator  the active game's playerView, or the lobby game's playerView, or none
-- ctx passed to enter: { role, readOnly (true for spectators), game (active id or nil) }.

local Core = script.Parent

local GameRegistry = {}
GameRegistry.ATTRIBUTE = "ActiveGame"

local entries = {}
local loaded = false

function GameRegistry.register(entry)
	assert(type(entry) == "table" and type(entry.id) == "string" and entry.id ~= "", "GameRegistry: entry needs an id")
	assert(type(entry.name) == "string", "GameRegistry: " .. entry.id .. " needs a display name")
	for _, key in ipairs({ "playerView", "robotView" }) do
		assert(typeof(entry[key]) == "Instance" and entry[key]:IsA("ModuleScript"),
			"GameRegistry: " .. entry.id .. "." .. key .. " must be a ModuleScript")
	end
	entries[entry.id] = entry
	return entry
end

local function load()
	if loaded then
		return
	end
	loaded = true
	local folder = Core:FindFirstChild("Games")
	for _, module in ipairs(folder and folder:GetChildren() or {}) do
		if module:IsA("ModuleScript") then
			local ok, entry = pcall(require, module)
			if ok then
				local registered, err = pcall(GameRegistry.register, entry)
				if not registered then
					warn("[GameRegistry] " .. module.Name .. ": " .. tostring(err))
				end
			else
				warn("[GameRegistry] " .. module.Name .. " failed to load: " .. tostring(entry))
			end
		end
	end
end

function GameRegistry.get(id)
	load()
	return id and entries[id] or nil
end

function GameRegistry.all()
	load()
	local list = {}
	for _, entry in pairs(entries) do
		table.insert(list, entry)
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

function GameRegistry.lobbyEntry()
	for _, entry in ipairs(GameRegistry.all()) do
		if entry.lobby then
			return entry
		end
	end
	return nil
end

function GameRegistry.active()
	return Core:GetAttribute(GameRegistry.ATTRIBUTE)
end

-- Server only. id = a registered game, or nil for the lobby.
function GameRegistry.setActive(id)
	if id ~= nil and GameRegistry.get(id) == nil then
		warn("[GameRegistry] setActive: unknown game " .. tostring(id))
	end
	if Core:GetAttribute(GameRegistry.ATTRIBUTE) ~= id then
		Core:SetAttribute(GameRegistry.ATTRIBUTE, id)
	end
end

function GameRegistry.activeChanged()
	return Core:GetAttributeChangedSignal(GameRegistry.ATTRIBUTE)
end

-- The view module a client with `role` shows. Pure: activeEntry / lobbyEntry are entries or nil, and
-- defaultRobotView is the lobby robot view (Core.Views.LobbyRobotView when left out).
function GameRegistry.viewFor(role, activeEntry, lobbyEntry, defaultRobotView)
	if role == "robot" then
		if activeEntry and activeEntry.robotView then
			return activeEntry.robotView
		end
		return defaultRobotView or Core:FindFirstChild("Views") and Core.Views:FindFirstChild("LobbyRobotView")
	elseif role == "player" or role == "spectator" then
		if activeEntry then
			return activeEntry.playerView
		end
		return lobbyEntry and lobbyEntry.playerView or nil
	end
	return nil
end

return GameRegistry
