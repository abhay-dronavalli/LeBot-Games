-- ServerScriptService.PatternMode
-- Wires up Pattern Match: the remotes, the "Play Pattern Match" prompt on PatternCabinet.Entry, the mode
-- pick from the mode select screen, the click-to-spin boards, and the game loop in
-- ReplicatedStorage.PatternMatch.Game (which holds the state machine).
-- Roles (Core.Roles): only the player role can start a game, pick a mode, cycle tickets or spin the
-- TargetBoard; calls from the robot or a spectator are dropped. The robot role gets its own HUD payload
-- (RobotUI, Game.robotPayload) and never the full one. Pattern Match is Core.GameRegistry's active game from
-- mode select until Results end.
-- Testing hook, server only: PatternMatch.Debug:Fire({ op = "start", mode = "easy" / "hard" }) starts a
-- game as if the player had pressed Play and picked that mode (no player needed: solo robot testing);
-- { op = "endShift" } ends the running shift (Results).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch.Config)
local Game = require(PatternMatch.Game)
local BoardSpinner = require(PatternMatch.BoardSpinner)
local ArmTwin = ReplicatedStorage:WaitForChild("ArmTwin")
local TwinDriver = require(ArmTwin:WaitForChild("Driver"))
local Stick = require(ArmTwin:WaitForChild("Stick"))
local Core = ReplicatedStorage:WaitForChild("Core")
local StateStore = require(Core:WaitForChild("StateStore"))
local Events = require(Core:WaitForChild("Events"))
local Roles = require(Core:WaitForChild("Roles"))
local GameRegistry = require(Core:WaitForChild("GameRegistry"))

local GAME_ID = "PatternMatch" -- Core.Games.PatternMatch

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
local patternUI = getOrCreate(remotes, "RemoteEvent", "PatternUI")          -- server -> player, spectators: HUD payload
local robotUI = getOrCreate(remotes, "RemoteEvent", "RobotUI")              -- server -> robot: Game.robotPayload
local patternRefresh = getOrCreate(remotes, "RemoteEvent", "PatternRefresh") -- any client -> server: send me the HUD now
local patternPick = getOrCreate(remotes, "RemoteEvent", "PatternPick")      -- player -> server: "easy" / "hard"
local ticketCycle = getOrCreate(remotes, "RemoteEvent", "TicketCycle")      -- player -> server: -1 / +1 through the tickets
local patternState = getOrCreate(remotes, "BindableEvent", "PatternState")  -- server only: state changes
local armPose = getOrCreate(remotes, "UnreliableRemoteEvent", "ArmPose")    -- server -> clients: arm points, 20 Hz
local debugHook = getOrCreate(PatternMatch, "BindableEvent", "Debug")       -- server only: testing

local cabinet = workspace:WaitForChild("PatternCabinet")
local prompt = cabinet:WaitForChild("Entry"):WaitForChild("PlayPrompt")

local patternGame = Game.new({
	cabinet = cabinet,
	store = StateStore,
	core = Events,
	ui = patternUI,
	robotUi = robotUI,
	players = function()
		return Players:GetPlayers()
	end,
	roleOf = Roles.of,
	onActive = function(active)
		GameRegistry.setActive(active and GAME_ID or nil)
	end,
	stateChanged = patternState,
})

prompt.Triggered:Connect(Roles.guard(function(player)
	if patternGame:start(player) then
		print("[PatternMode] " .. player.Name .. " started a game")
	end
end, "Play Pattern Match"))

patternPick.OnServerEvent:Connect(Roles.guard(function(player, choice)
	patternGame:pick(player, choice)
end, "PatternPick"))

ticketCycle.OnServerEvent:Connect(Roles.guard(function(player, dir)
	patternGame:cycleTicket(player, dir)
end, "TicketCycle"))

patternRefresh.OnServerEvent:Connect(function(player)
	patternGame:pushUI(player) -- read only: the payload for this player's role
end)

debugHook.Event:Connect(function(cmd)
	if type(cmd) ~= "table" then
		return
	end
	if cmd.op == "start" and patternGame:start(nil) then
		if patternGame.state == "ModeSelect" then
			patternGame:choose(cmd.mode == "hard" and "Hard" or "Easy", "Debug hook")
		end
		print("[PatternMode] Debug hook started a game")
	elseif cmd.op == "endShift" and patternGame.state == "Shift" then
		patternGame.timeLeft = 0 -- Results on the next tick
	end
end)

-- Click the TargetBoard to spin it 90 degrees (the player role only). Spins wait while clients are shaking
-- the boards for a tremor. The LiveBoard never spins: it and the arm twin stay fixed, like the real table.
for _, name in ipairs({ "TargetBoard" }) do -- the LiveBoard and its arm twin never spin
	local board = cabinet:WaitForChild(name)
	local spinner = BoardSpinner.new(board, {
		isShaking = function()
			return patternGame.events:tremorActive()
		end,
	})
	board:WaitForChild("SpinClick").MouseClick:Connect(Roles.guard(function()
		spinner:request()
	end, "SpinClick"))
end

-- The arm twin: clients draw a stick figure from these samples (Views.Player.PatternWorld.ArmTwinClient):
-- the bridge's arm.points as world positions over the LiveBoard. While the attract demo runs (Idle), and
-- while the link is OFFLINE or the arm data is stale, nothing goes out, so the twin rests in its folded pose.
local liveBoard = cabinet:WaitForChild("LiveBoard")
TwinDriver.serve(armPose, function()
	if patternGame.attract.running or StateStore.status() == "offline" then
		return nil
	end
	local s = StateStore.get()
	local armAge = tonumber(s.arm_age) -- null: no arm published yet
	if s.arm == nil or armAge == nil or armAge > Config.bridgeStaleSeconds then
		return nil
	end
	return Stick.payload(s.arm.points, liveBoard)
end, 20)

-- A player who joins mid-game, or whose role changes, gets the current HUD state right away.
Players.PlayerAdded:Connect(function(player)
	patternGame:pushUI(player)
	player:GetAttributeChangedSignal(Roles.ATTRIBUTE):Connect(function()
		patternGame:pushUI(player)
	end)
end)

patternGame:run()
