-- ReplicatedStorage.PatternMatch.Game
-- The Pattern Match game loop, run on the server by ServerScriptService.PatternMode:
--   Idle -> ModeSelect -> Round 1 -> Intermission -> Round 2 -> Intermission -> Round 3 -> Results -> Idle
-- Easy mode only for now (build step 3). Each state is an enter/tick pair in `states`, so Hard mode and
-- events can hook in later. Every 0.2 s the loop redraws the LiveBoard from StateStore (in every state,
-- idle included) and then ticks the current state.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local Target = require(script.Parent.Target)
local LiveBoard = require(script.Parent.LiveBoard)

local TICK = 0.2
local NEUTRAL = Color3.fromRGB(200, 200, 200)
local ROUNDS = #Config.blocksPerRound
local INTERMISSION_MESSAGE = "Clear the grid. Swap seats if you want."
local WAITING_MESSAGE = "Waiting for grid to clear"

local Game = {}
Game.__index = Game

-- A timer length from Config, in seconds, 4x shorter when Config.debugFastTimers is on.
local function seconds(s)
	return Config.debugFastTimers and s / 4 or s
end

local function log(fmt, ...)
	print("[PatternMode] " .. string.format(fmt, ...))
end

-- "A1=red B2=teal+red C3=yellow^1": + joins blocks sharing a cell, ^n counts stacked blocks.
local function describeLive(liveGrid)
	local parts = {}
	for cell, entry in pairs(liveGrid) do
		local text = cell .. "=" .. (#entry.colors > 0 and table.concat(entry.colors, "+") or "?")
		if entry.stacked > 0 then
			text ..= "^" .. entry.stacked
		end
		table.insert(parts, text)
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, " ") or "(empty)"
end

local function describeTarget(target)
	local parts = {}
	for cell, color in pairs(target) do
		table.insert(parts, cell .. "=" .. color)
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

local states = {}

states.Idle = {
	enter = function(self)
		self.mode, self.target = nil, nil -- score and roundScores stay, so the HUD shows the last game
		self:showTarget(nil)
		self.message = "Walk up to the pad and press E to play Pattern Match."
	end,
}

states.ModeSelect = {
	enter = function(self)
		self.mode, self.round, self.score, self.roundScores = nil, 0, 0, {}
		self:startTimer(Config.modeSelectSeconds)
		self.message = "Choosing a mode..."
	end,
	tick = function(self)
		if self.timeLeft <= 0 then
			self.mode = "Easy" -- the real mode select screen is build step 6
			self.round = 1
			self:setState("Round")
		end
	end,
}

states.Round = {
	enter = function(self)
		self.target = Target.generate(Config.blocksPerRound[self.round])
		self:showTarget(self.target)
		self:startTimer(Config.roundSeconds[self.round])
		self.clearFor = 0
		self.lastCompare = nil
		self.message = "Match the target!"
		log("round %d target: %s", self.round, describeTarget(self.target))
	end,
	tick = function(self, dt)
		local result = Target.compare(self.target, self.liveGrid, {})
		local text = Target.describe(result)
		if text ~= self.lastCompare then
			self.lastCompare = text
			log("round %d %s | live: %s", self.round, text, describeLive(self.liveGrid))
		end

		self.clearFor = result.clear and self.clearFor + dt or 0
		if self.clearFor >= seconds(Config.holdToClear) then
			self:endRound(math.floor(self.timeLeft), "clear")
		elseif self.timeLeft <= 0 then
			self:endRound(0, "time up")
		end
	end,
}

states.Intermission = {
	enter = function(self)
		self:startTimer(Config.intermissionSeconds)
		self.message = INTERMISSION_MESSAGE
	end,
	tick = function(self)
		if self.timeLeft > 0 then
			return
		end
		if next(self.liveGrid) == nil then
			self.round += 1
			self:setState("Round")
		elseif self.message ~= WAITING_MESSAGE then
			self.message = WAITING_MESSAGE
			log("intermission over, waiting for grid to clear: %s", describeLive(self.liveGrid))
			self:pushUI()
		end
	end,
}

states.Results = {
	enter = function(self)
		local parts = {}
		for r = 1, ROUNDS do
			table.insert(parts, string.format("R%d %d", r, self.roundScores[r] or 0))
		end
		self.message = string.format("Final score %d  (%s)", self.score, table.concat(parts, ", "))
		self:startTimer(Config.resultsSeconds)
		log("results: %s", self.message)
	end,
	tick = function(self)
		if self.timeLeft <= 0 then
			self:setState("Idle")
		end
	end,
}

-- opts: cabinet (Workspace.PatternCabinet), store (Core.StateStore), ui (PatternUI RemoteEvent),
-- stateChanged (optional BindableEvent, fired with { state, round, target } on every state change)
function Game.new(opts)
	local self = setmetatable({}, Game)
	self.store = opts.store
	self.ui = opts.ui
	self.stateChanged = opts.stateChanged
	self.targetBoard = opts.cabinet:WaitForChild("TargetBoard")
	self.liveBoard = LiveBoard.new(opts.cabinet:WaitForChild("LiveBoard"))
	self.liveGrid = {}
	self.state = "Idle"
	self.mode, self.round, self.score, self.roundScores = nil, 0, 0, {}
	self.timeLeft, self.timerRunning, self.message = 0, false, ""
	return self
end

-- Starts a game. Returns false (and does nothing) if one is already running.
function Game:start()
	if self.state ~= "Idle" then
		return false
	end
	self:setState("ModeSelect")
	return true
end

-- Runs forever: redraw the LiveBoard, count down, tick the current state.
function Game:run()
	self:setState("Idle")
	while true do
		local dt = task.wait(TICK)
		self.liveGrid = self.liveBoard:render(self.store.get().blocks)
		if self.timerRunning then
			self.timeLeft = math.max(0, self.timeLeft - dt)
			local shown = math.ceil(self.timeLeft)
			if shown ~= self.shownSeconds then
				self.shownSeconds = shown
				self:pushUI()
			end
		end
		local tick = states[self.state].tick
		if tick then
			tick(self, dt)
		end
	end
end

function Game:setState(name)
	self.state = name
	self.timerRunning = false
	self.timeLeft = 0
	states[name].enter(self)
	log("state %s%s", name, self.round > 0 and name ~= "Idle" and (" (round " .. self.round .. ")") or "")
	self:pushUI()
	if self.stateChanged then
		self.stateChanged:Fire({ state = name, round = self.round, target = self.target })
	end
end

function Game:startTimer(s)
	self.timeLeft = seconds(s)
	self.shownSeconds = math.ceil(self.timeLeft)
	self.timerRunning = true
end

function Game:endRound(points, why)
	self.roundScores[self.round] = points
	self.score += points
	log("round %d %s: %d points (total %d)", self.round, why, points, self.score)
	self:setState(self.round < ROUNDS and "Intermission" or "Results")
end

-- Colors the TargetBoard: target cells in their color, everything else neutral. nil blanks it.
function Game:showTarget(target)
	for _, cell in ipairs(Grid.allCells()) do
		local colorName = target and target[cell]
		self.targetBoard[cell].Color = colorName and Config.colors[colorName] or NEUTRAL
	end
end

function Game:payload()
	return {
		state = self.state,
		mode = self.mode,
		round = self.round,
		timeLeft = self.timerRunning and math.ceil(self.timeLeft) or 0,
		score = self.score,
		message = self.message,
		roundScores = table.clone(self.roundScores),
	}
end

-- Sends the HUD payload to one player, or to everyone when player is nil.
function Game:pushUI(player)
	if player then
		self.ui:FireClient(player, self:payload())
	else
		self.ui:FireAllClients(self:payload())
	end
end

return Game
