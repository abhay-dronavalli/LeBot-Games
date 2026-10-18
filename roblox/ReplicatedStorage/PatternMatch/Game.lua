-- ReplicatedStorage.PatternMatch.Game
-- The Pattern Match game loop, run on the server by ServerScriptService.PatternMode:
--   Idle -> ModeSelect -> Round 1 -> Intermission -> Round 2 -> Intermission -> Round 3 -> Results -> Idle
-- Easy and Hard modes, with events during rounds (PatternMatch.PatternEvents). Each state is an
-- enter/tick pair in `states`. Every 0.2 s, step() redraws the LiveBoard from StateStore (in every
-- state, idle included), counts down, ticks the current state and pushes the HUD payload if anything
-- on it changed.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local Target = require(script.Parent.Target)
local LiveBoard = require(script.Parent.LiveBoard)
local TargetBoard = require(script.Parent.TargetBoard)
local PatternEvents = require(script.Parent.PatternEvents)

local TICK = 0.2
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

-- "A1=red B2=teal/red C3=yellow|purple": / joins levels bottom to top, | joins blocks doubled on one
-- level, and a level with nothing under it shows as "-" (e.g. "A1=-/red" for a level 1 block alone).
local function describeLive(liveGrid)
	local parts = {}
	for cell, entry in pairs(liveGrid) do
		local levels = Grid.levelsOf(entry)
		local texts = {}
		for level = 0, levels[#levels] do
			table.insert(texts, entry[level] and table.concat(entry[level], "|") or "-")
		end
		table.insert(parts, cell .. "=" .. table.concat(texts, "/"))
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, " ") or "(empty)"
end

-- "A1=red B2=teal/red": / joins a tower's colors bottom to top.
local function describeTarget(target)
	local parts = {}
	for cell, tower in pairs(target) do
		table.insert(parts, cell .. "=" .. table.concat(tower, "/"))
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

-- Hard mode reveal cycle: seconds since round start -> "show" or "hide", and seconds left in that
-- phase. Every round starts with "show" for Config.hard.showSeconds, then "hide" for hideSeconds.
function Game.revealAt(elapsed)
	local show, hide = seconds(Config.hard.showSeconds), seconds(Config.hard.hideSeconds)
	local t = elapsed % (show + hide)
	if t < show then
		return "show", show - t
	end
	return "hide", show + hide - t
end

local states = {}

states.Idle = {
	enter = function(self)
		self.mode, self.target = nil, nil -- score and roundScores stay, so the HUD shows the last game
		self.targetBoard:show(nil)
		self.message = "Walk up to the pad and press E to play Pattern Match."
	end,
}

-- The player who started picks on the mode select screen (StarterGui.PatternModeSelect) through the
-- PatternPick remote -> Game:pick. No pick by the end of the countdown means Easy. After a pick the
-- state holds for Config.modeConfirmSeconds ("HARD MODE") before round 1.
states.ModeSelect = {
	enter = function(self)
		self.mode, self.round, self.score, self.roundScores = nil, 0, 0, {}
		self.picked = false
		self:startTimer(Config.modeSelectSeconds)
		self.message = (self.chooserName or "Someone") .. " is choosing a mode"
	end,
	tick = function(self, dt)
		if self.picked then
			self.confirmLeft -= dt
			if self.confirmLeft <= 0 then
				self.round = 1
				self:setState("Round")
			end
		elseif self.timeLeft <= 0 then
			self:choose("Easy", "auto-picked at 0")
		end
	end,
}

states.Round = {
	enter = function(self)
		self.target = Target.generate(Config.blocksPerRound[self.round], Config.maxStackByRound[self.round] or 1)
		self:startTimer(Config.roundSeconds[self.round])
		self.roundElapsed = 0
		self.clearFor = 0
		self.lastCompare = nil
		self.message = "Match the target!"
		if self.mode == "Hard" then
			self.revealPhase, self.revealLeft = Game.revealAt(0)
		end
		self.targetBoard:show(self.target, false, self.mode == "Hard")
		self.events:startRound(self.mode)
		log("round %d target: %s", self.round, describeTarget(self.target))
	end,
	tick = function(self, dt)
		self.roundElapsed += dt
		self.events:tick(dt, self.target, self.liveGrid)
		if self.mode == "Hard" then
			local phase, left = Game.revealAt(self.roundElapsed)
			self.revealLeft = left
			if phase ~= self.revealPhase then
				self.revealPhase = phase
				self.targetBoard:show(self.target, phase == "hide", true)
				log("round %d colors %s at %.1f s", self.round, phase == "hide" and "hidden" or "visible", self.roundElapsed)
			end
		end

		local result = Target.compare(self.target, self.liveGrid, self.events.vanished)
		self.liveBoard:showProblems(result.problemLevels) -- extra, doubled and blocked blocks
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
		self.targetBoard:show(self.target, false, false) -- full colors: the answer to the round just played
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
		self.targetBoard:show(self.target, false, false)
		local parts = {}
		for r = 1, ROUNDS do
			table.insert(parts, string.format("R%d %d", r, self.roundScores[r] or 0))
		end
		self.message = string.format("Final score %d  (%s)", self.score, table.concat(parts, ", "))
		self:startTimer(Config.resultsSeconds)
		log("results (%s mode): %s", self.mode, self.message)
	end,
	tick = function(self)
		if self.timeLeft <= 0 then
			self:setState("Idle")
		end
	end,
}

-- opts: cabinet (Workspace.PatternCabinet), store (Core.StateStore), core (Core.Events),
-- ui (PatternUI RemoteEvent), stateChanged (optional BindableEvent, fired with { state, round, target }
-- on every state change)
function Game.new(opts)
	local self = setmetatable({}, Game)
	self.store = opts.store
	self.ui = opts.ui
	self.stateChanged = opts.stateChanged
	local targetModel = opts.cabinet:WaitForChild("TargetBoard")
	local liveModel = opts.cabinet:WaitForChild("LiveBoard")
	self.targetBoard = TargetBoard.new(targetModel)
	self.liveBoard = LiveBoard.new(liveModel)
	self.events = PatternEvents.new({ core = opts.core, liveBoard = self.liveBoard })
	self.liveGrid = {}
	self.state = "Idle"
	self.mode, self.round, self.score, self.roundScores = nil, 0, 0, {}
	self.timeLeft, self.timerRunning, self.message = 0, false, ""
	return self
end

-- Starts a game for the player who pressed Play; that player picks the mode. Returns false (and does
-- nothing) if one is already running. Config.debugForceMode skips the mode select screen.
function Game:start(player)
	if self.state ~= "Idle" then
		return false
	end
	self.chooserName = player and player.Name or nil
	self.chooserUserId = player and player.UserId or nil
	local forced = Config.debugForceMode
	if forced == "easy" or forced == "hard" then
		self.mode, self.round, self.score, self.roundScores = forced == "hard" and "Hard" or "Easy", 1, 0, {}
		log("mode %s (debugForceMode)", self.mode)
		self:setState("Round")
	else
		self:setState("ModeSelect")
	end
	return true
end

-- A mode pick from a client ("easy" or "hard"). Accepted only from the player who started, only during
-- ModeSelect, and only once. Returns true if accepted.
function Game:pick(player, choice)
	local mode = (choice == "easy" and "Easy") or (choice == "hard" and "Hard") or nil
	if self.state ~= "ModeSelect" or self.picked or mode == nil or player == nil
		or player.UserId ~= self.chooserUserId then
		log("pick rejected: %s chose %s during %s", player and player.Name or "?", tostring(choice), self.state)
		return false
	end
	self:choose(mode, "picked by " .. player.Name)
	return true
end

function Game:choose(mode, why)
	self.mode = mode
	self.picked = true
	self.timerRunning = false
	self.confirmLeft = seconds(Config.modeConfirmSeconds)
	self.message = string.upper(mode) .. " MODE"
	log("mode %s (%s)", mode, why)
	self:pushUI()
end

-- Runs forever, one step per tick.
function Game:run()
	self:setState("Idle")
	while true do
		self:step(task.wait(TICK))
	end
end

-- One tick: redraw the LiveBoard, count down, tick the current state, update the HUD if it changed.
function Game:step(dt)
	self.liveGrid = self.liveBoard:render(self.store.get().blocks)
	if self.timerRunning then
		self.timeLeft = math.max(0, self.timeLeft - dt)
	end
	local tick = states[self.state].tick
	if tick then
		tick(self, dt)
	end
	if self:hudKey() ~= self.pushedKey then
		self:pushUI()
	end
end

function Game:setState(name)
	self.state = name
	self.timerRunning = false
	self.timeLeft = 0
	self.revealPhase, self.revealLeft = nil, nil
	self.events:stopRound()
	self.liveBoard:showProblems(nil)
	states[name].enter(self)
	log("state %s%s", name, self.round > 0 and name ~= "Idle" and (" (round " .. self.round .. ", " .. tostring(self.mode) .. ")") or "")
	self:pushUI()
	if self.stateChanged then
		self.stateChanged:Fire({ state = name, round = self.round, target = self.target })
	end
end

function Game:startTimer(s)
	self.timeLeft = seconds(s)
	self.timerRunning = true
end

function Game:endRound(points, why)
	self.roundScores[self.round] = points
	self.score += points
	log("round %d %s: %d points (total %d)", self.round, why, points, self.score)
	self:setState(self.round < ROUNDS and "Intermission" or "Results")
end

function Game:payload()
	local event, vanishedCells = self.events:payload()
	return {
		state = self.state,
		mode = self.mode,
		round = self.round,
		timeLeft = self.timerRunning and math.ceil(self.timeLeft) or 0,
		score = self.score,
		message = self.message,
		roundScores = table.clone(self.roundScores),
		revealPhase = self.revealPhase,
		revealTimeLeft = self.revealPhase and math.ceil(self.revealLeft) or nil,
		event = event,                 -- { name, banner, phase = "warning" | "active", timeLeft } or nil
		vanishedCells = vanishedCells, -- sorted list of cells
		chooser = self.chooserName,    -- who picks the mode this game
		chooserUserId = self.chooserUserId,
		confirming = self.state == "ModeSelect" and self.picked == true, -- picked, showing "HARD MODE"
	}
end

-- The parts of the payload that change during a state; a new value means the HUD needs a push.
function Game:hudKey()
	local p = self:payload()
	local event = p.event and (p.event.name .. ":" .. p.event.phase .. ":" .. p.event.timeLeft) or "-"
	return string.format("%d|%s|%s|%s|%s", p.timeLeft, tostring(p.revealPhase), tostring(p.revealTimeLeft),
		event, table.concat(p.vanishedCells, ","))
end

-- Sends the HUD payload to one player, or to everyone when player is nil.
function Game:pushUI(player)
	if player then
		self.ui:FireClient(player, self:payload())
	else
		self.pushedKey = self:hudKey()
		self.ui:FireAllClients(self:payload())
	end
end

return Game
