-- ServerScriptService.PatternMode
-- Wires up Pattern Match: the remotes, the "Play Pattern Match" prompt on PatternCabinet.Entry, the mode
-- pick from the mode select screen, the click-to-spin boards, and the game loop in
-- ReplicatedStorage.PatternMatch.Game (which holds the state machine).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Game = require(PatternMatch.Game)
local BoardSpinner = require(PatternMatch.BoardSpinner)
local TwinDriver = require(ReplicatedStorage:WaitForChild("ArmTwin"):WaitForChild("Driver"))
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
local patternPick = getOrCreate(remotes, "RemoteEvent", "PatternPick")      -- chooser -> server: "easy" / "hard"
local ticketPick = getOrCreate(remotes, "RemoteEvent", "TicketPick")        -- any player -> server: ticket id to make active
local patternState = getOrCreate(remotes, "BindableEvent", "PatternState")  -- server only: state changes
local armPose = getOrCreate(remotes, "UnreliableRemoteEvent", "ArmPose")    -- server -> clients: arm angles, 20 Hz

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
	if patternGame:start(player) then
		print("[PatternMode] " .. player.Name .. " started a game")
	end
end)

patternPick.OnServerEvent:Connect(function(player, choice)
	patternGame:pick(player, choice)
end)

ticketPick.OnServerEvent:Connect(function(player, id)
	patternGame:selectTicket(player, id)
end)

-- Click the TargetBoard to spin it 90 degrees. Spins wait while clients are shaking the boards for a
-- tremor. The LiveBoard never spins: it and the arm twin stay fixed, like the real table.
for _, name in ipairs({ "TargetBoard" }) do -- the LiveBoard and its arm twin never spin
	local board = cabinet:WaitForChild(name)
	local spinner = BoardSpinner.new(board, {
		isShaking = function()
			return patternGame.events:tremorActive()
		end,
	})
	board:WaitForChild("SpinClick").MouseClick:Connect(function()
		spinner:request()
	end)
end

-- The arm twin: clients drive their copy of the rig from these samples (StarterPlayerScripts.ArmTwinClient).
-- While the attract demo runs (Idle) no arm data goes out, so the twin rests in its folded pose.
TwinDriver.serve(armPose, function()
	if patternGame.attract.running then
		return nil
	end
	return StateStore.get().arm
end, 20)

-- A player who joins mid-game gets the current HUD state right away.
Players.PlayerAdded:Connect(function(player)
	patternGame:pushUI(player)
end)

patternGame:run()
