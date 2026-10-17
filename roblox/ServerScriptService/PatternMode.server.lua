-- ServerScriptService.PatternMode
-- Wires up Pattern Match: the remotes, the "Play Pattern Match" prompt on PatternCabinet.Entry, and the
-- game loop in ReplicatedStorage.PatternMatch.Game (which holds the state machine).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Game = require(PatternMatch.Game)
local Core = ReplicatedStorage:WaitForChild("Core")
local StateStore = require(Core:WaitForChild("StateStore"))
local Events = require(Core:WaitForChild("Events"))

local function getOrCreate(parent, className, name)
	local child = parent:FindFirstChild(name)
	if not child then
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end

local remotes = getOrCreate(PatternMatch, "Folder", "Remotes")
local patternUI = getOrCreate(remotes, "RemoteEvent", "PatternUI")          -- server -> clients: HUD payload
local patternState = getOrCreate(remotes, "BindableEvent", "PatternState")  -- server only: state changes

local cabinet = workspace:WaitForChild("PatternCabinet")
local prompt = cabinet:WaitForChild("Entry"):WaitForChild("PlayPrompt")

local patternGame = Game.new({
	cabinet = cabinet,
	store = StateStore,
	core = Events,
	ui = patternUI,
	stateChanged = patternState,
})

prompt.Triggered:Connect(function(player)
	if patternGame:start() then
		print("[PatternMode] " .. player.Name .. " started a game")
	end
end)

-- A player who joins mid-game gets the current HUD state right away.
Players.PlayerAdded:Connect(function(player)
	patternGame:pushUI(player)
end)

patternGame:run()
