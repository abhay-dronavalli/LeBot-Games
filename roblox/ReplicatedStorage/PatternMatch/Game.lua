-- ReplicatedStorage.PatternMatch.Game
-- The Pattern Match game loop, a Papa's-style ticket shift, run on the server by
-- ServerScriptService.PatternMode:
--   Idle -> ModeSelect -> Shift -> Results -> Idle
-- A shift is one countdown (Config.shiftSeconds). Tickets (target patterns) arrive on a rail: the first
-- at shift start, then one every Config.ticketIntervalMin..Max seconds, the arrival timer paused while
-- the rail holds Config.ticketRailMax. One ticket is ACTIVE (the oldest by default, or the one a player
-- clicks): the TargetBoard shows it, and when the live board matches it exactly for Config.holdToClear
-- it completes: ORDER UP, points, +Config.ticketTimeBonus seconds, off the rail, and the oldest
-- remaining ticket becomes active (an empty rail gets the next ticket right away). Blocks stay on the
-- board between tickets. The shift ends when the timer hits 0: Results, then Idle.
-- While Idle, PatternMatch.Attract plays a demo loop on both boards (Config.attractEnabled); it stops and
-- clears both boards the moment any other state starts, and the LiveBoard isn't drawn from StateStore
-- while it runs.
-- Easy and Hard modes; events (PatternMatch.PatternEvents) run during the shift. Each state is an
-- enter/tick pair in `states`. Every 0.2 s, step() redraws the LiveBoard from StateStore (in every
-- state, idle included), counts down, ticks the current state and pushes the HUD payload if anything
-- on it changed.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local Target = require(script.Parent.Target)
local LiveBoard = require(script.Parent.LiveBoard)
local TargetBoard = require(script.Parent.TargetBoard)
local PatternEvents = require(script.Parent.PatternEvents)
local Attract = require(script.Parent.Attract)
local Celebrate = require(script.Parent.Celebrate)
local TicketStack = require(script.Parent.TicketStack)

local TICK = 0.2

local Game = {}
Game.__index = Game

-- A timer length from Config, in seconds, 4x shorter when Config.debugFastTimers is on.
local function seconds(s)
	return Config.debugFastTimers and s / 4 or s
end
Game.seconds = seconds

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

-- Points a ticket is worth: Config.ticketPoints.ticket, plus .flat per level 0 block and .stacked per
-- block above it. Default 1 + 1 per flat + 3 per stacked: 2 flat + 1 on top = 6.
function Game.ticketPoints(target)
	local P = Config.ticketPoints
	local points = P.ticket
	for _, tower in pairs(target) do
		for i = 1, #tower do
			points += i == 1 and P.flat or P.stacked
		end
	end
	return points
end

-- Stack chance for a ticket arriving `elapsed` seconds into a shift `length` seconds long: a straight
-- ramp from Config.stackChanceStart to Config.stackChanceEnd.
function Game.stackChanceAt(elapsed, length)
	local t = length > 0 and math.clamp(elapsed / length, 0, 1) or 0
	return Config.stackChanceStart + (Config.stackChanceEnd - Config.stackChanceStart) * t
end

-- Hard mode reveal cycle: seconds since shift start -> "show" or "hide", and seconds left in that
-- phase. The shift starts with "show" for Config.hard.showSeconds, then "hide" for hideSeconds.
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
		self.mode = nil -- score and completed stay, so the HUD shows the last shift
		self.tickets, self.activeId = {}, nil
		if Config.attractEnabled then
			self.attract:start() -- draws its own boards; a no-op when it is already running
		else
			self.targetBoard:show(nil)
		end
		self.message = "Walk up to the pad and press E to play Pattern Match."
	end,
}

-- The player who started picks on the mode select screen (StarterGui.PatternModeSelect) through the
-- PatternPick remote -> Game:pick. No pick by the end of the countdown means Easy. After a pick the
-- state holds for Config.modeConfirmSeconds ("HARD MODE") before the shift.
states.ModeSelect = {
	enter = function(self)
		self.mode, self.score, self.completed = nil, 0, {}
		self.picked = false
		self:startTimer(Config.modeSelectSeconds)
		self.message = (self.chooserName or "Someone") .. " is choosing a mode"
	end,
	tick = function(self, dt)
		if self.picked then
			self.confirmLeft -= dt
			if self.confirmLeft <= 0 then
				self:setState("Shift")
			end
		elseif self.timeLeft <= 0 then
			self:choose("Easy", "auto-picked at 0")
		end
	end,
}

states.Shift = {
	enter = function(self)
		self.tickets, self.activeId, self.completed = {}, nil, {}
		self.nextTicketId = 1 -- tickets are numbered from #1 every shift
		self.score = 0
		self.shiftElapsed = 0
		self.shiftLength = seconds(Config.shiftSeconds)
		self.clearFor = 0
		self.lastCompare = nil
		self.orderUp = nil
		self:startTimer(Config.shiftSeconds)
		self.message = "Tickets are coming in. Match the active ticket!"
		if self.mode == "Hard" then
			self.revealPhase, self.revealLeft = Game.revealAt(0)
		end
		self.events:start(self.mode)
		self:addTicket() -- the first ticket arrives at shift start
		self:scheduleArrival()
	end,
	tick = function(self, dt)
		self.shiftElapsed += dt
		-- Arrivals. The timer pauses while the rail is full.
		if #self.tickets < Config.ticketRailMax then
			self.arrivalIn -= dt
			if self.arrivalIn <= 0 then
				self:addTicket()
				self:scheduleArrival()
			end
		end

		local active = self:activeTicket()
		self.events:tick(dt, active and active.target or {}, self.liveGrid)
		if self.mode == "Hard" then
			local phase, left = Game.revealAt(self.shiftElapsed)
			self.revealLeft = left
			if phase ~= self.revealPhase then
				self.revealPhase = phase
				self:showActive()
			end
		end

		if active then
			local result = Target.compare(active.target, self.liveGrid, self.events.vanished)
			self.liveBoard:showProblems(result.problemLevels) -- extra, doubled and blocked blocks
			local text = Target.describe(result)
			if text ~= self.lastCompare then
				self.lastCompare = text
				log("ticket #%d %s | live: %s", active.id, text, describeLive(self.liveGrid))
			end
			self.clearFor = result.clear and self.clearFor + dt or 0
			if self.clearFor >= seconds(Config.holdToClear) then
				self:completeTicket(active)
			end
		else
			self.liveBoard:showProblems(nil)
			self.clearFor = 0
		end

		if self.timeLeft <= 0 then
			self:setState("Results")
		end
	end,
}

states.Results = {
	enter = function(self)
		self.tickets, self.activeId = {}, nil
		self.targetBoard:show(nil)
		self.message = string.format("Shift over! %d ticket%s, %d points", #self.completed,
			#self.completed == 1 and "" or "s", self.score)
		self:startTimer(Config.resultsSeconds)
		log("results (%s mode): %s", tostring(self.mode), self.message)
	end,
	tick = function(self)
		if self.timeLeft <= 0 then
			self:setState("Idle")
		end
	end,
}

-- opts: cabinet (Workspace.PatternCabinet), store (Core.StateStore), core (Core.Events),
-- ui (PatternUI RemoteEvent), stateChanged (optional BindableEvent, fired with
-- { state, mode, activeId, target } on every state change and every active ticket change, where target
-- is the active ticket's target), rng (optional Random for tickets, for repeatable tests), manualAttract
-- (true: the attract demo only moves when tests call game.attract:advance(dt))
function Game.new(opts)
	local self = setmetatable({}, Game)
	self.store = opts.store
	self.ui = opts.ui
	self.stateChanged = opts.stateChanged
	self.rng = opts.rng or Random.new()
	local targetModel = opts.cabinet:WaitForChild("TargetBoard")
	local liveModel = opts.cabinet:WaitForChild("LiveBoard")
	self.targetBoard = TargetBoard.new(targetModel)
	self.liveBoard = LiveBoard.new(liveModel)
	self.events = PatternEvents.new({ core = opts.core, liveBoard = self.liveBoard })
	-- The shared "matched" moment: the attract demo's COMPLETE! and the shift's ORDER UP.
	self.celebrate = Celebrate.new(opts.cabinet, { targetModel, liveModel })
	self.attract = Attract.new({ cabinet = opts.cabinet, targetBoard = self.targetBoard, liveBoard = self.liveBoard,
		celebrate = self.celebrate, manual = opts.manualAttract })
	self.liveGrid = {}
	self.state = "Idle"
	self.mode, self.score, self.completed = nil, 0, {}
	self.tickets, self.activeId, self.nextTicketId = {}, nil, 1
	self.orderUpSeq = 0
	self.shiftElapsed, self.shiftLength = 0, seconds(Config.shiftSeconds)
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
		self.mode = forced == "hard" and "Hard" or "Easy"
		log("mode %s (debugForceMode)", self.mode)
		self:setState("Shift")
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

-- Tickets --------------------------------------------------------------------------------------------

function Game:activeTicket()
	for _, ticket in ipairs(self.tickets) do
		if ticket.id == self.activeId then
			return ticket
		end
	end
	return nil
end

-- A new ticket on the right end of the rail: ticketBlocksMin..Max blocks, towers up to maxStackGlobal,
-- stack chance from the ramp. It becomes active when nothing is.
function Game:addTicket()
	local n = self.rng:NextInteger(Config.ticketBlocksMin, Config.ticketBlocksMax)
	local chance = Game.stackChanceAt(self.shiftElapsed, self.shiftLength)
	local target = Target.generate(n, Config.maxStackGlobal, self.rng, chance)
	local _, tallest = Target.count(target)
	local ticket = {
		id = self.nextTicketId, target = target, blocks = n, points = Game.ticketPoints(target),
		stacked = tallest > 1, arrivedAt = self.shiftElapsed,
	}
	self.nextTicketId += 1
	table.insert(self.tickets, ticket)
	log("ticket #%d arrives (%d on the rail, stack chance %.2f): %s = %d points", ticket.id, #self.tickets,
		chance, describeTarget(target), ticket.points)
	if self.activeId == nil then
		self:setActive(ticket.id, "first on the rail")
	end
	self:pushUI()
	return ticket
end

function Game:scheduleArrival()
	self.arrivalIn = seconds(self.rng:NextNumber(Config.ticketIntervalMin, Config.ticketIntervalMax))
end

-- Makes ticket `id` active: the TargetBoard shows it and the hold-to-clear count starts over.
function Game:setActive(id, why)
	self.activeId = id
	self.clearFor = 0
	self.lastCompare = nil
	self:showActive()
	log("ticket #%s active (%s)", tostring(id), why)
	self:notify()
end

function Game:showActive()
	local ticket = self:activeTicket()
	local hard = self.mode == "Hard"
	self.targetBoard:show(ticket and ticket.target or nil, hard and self.revealPhase == "hide", hard)
end

-- Makes ticket `id` active, if it is on the rail (during the shift). Any player may. Returns true if it
-- changed the active ticket. Game:cycleTicket uses it; tests call it directly.
function Game:selectTicket(player, id)
	if self.state ~= "Shift" or type(id) ~= "number" or id == self.activeId then
		return false
	end
	for _, ticket in ipairs(self.tickets) do
		if ticket.id == id then
			self:setActive(id, "picked by " .. (player and player.Name or "?"))
			self:pushUI()
			return true
		end
	end
	return false
end

-- A player cycled the ticket stack (TicketCycle remote: Q / R keys or the < > arrows): dir -1 or +1
-- through the rail, oldest first, wrapping around. Returns true if the active ticket changed.
function Game:cycleTicket(player, dir)
	if self.state ~= "Shift" or (dir ~= 1 and dir ~= -1) or #self.tickets < 2 then
		return false
	end
	local ids = {}
	for _, ticket in ipairs(self.tickets) do
		table.insert(ids, ticket.id)
	end
	local nextId = TicketStack.cycledId(ids, self.activeId, dir)
	if nextId == nil or nextId == self.activeId then
		return false
	end
	self:setActive(nextId, string.format("%s by %s", dir > 0 and "next" or "previous", player and player.Name or "?"))
	self:pushUI()
	return true
end

-- The board matched the active ticket long enough: ORDER UP.
function Game:completeTicket(ticket)
	for i, t in ipairs(self.tickets) do
		if t.id == ticket.id then
			table.remove(self.tickets, i)
			break
		end
	end
	self.score += ticket.points
	table.insert(self.completed, {
		id = ticket.id, points = ticket.points, blocks = ticket.blocks, stacked = ticket.stacked,
		seconds = math.floor(self.shiftElapsed - ticket.arrivedAt + 0.5),
	})
	self.timeLeft += seconds(Config.ticketTimeBonus)
	self.orderUpSeq += 1
	self.orderUp = { id = ticket.id, points = ticket.points, bonus = Config.ticketTimeBonus, seq = self.orderUpSeq }
	self.message = string.format("ORDER UP! Ticket #%d +%d", ticket.id, ticket.points)
	self.celebrate:burst(string.format("ORDER UP! +%d", ticket.points)) -- same moment as the demo's COMPLETE!
	log("ORDER UP: ticket #%d, +%d points (score %d), +%d s", ticket.id, ticket.points, self.score, Config.ticketTimeBonus)
	self.activeId = nil
	if #self.tickets == 0 then
		self:addTicket() -- the rail is empty: the next ticket arrives right away
		self:scheduleArrival()
	else
		self:setActive(self.tickets[1].id, "oldest after ORDER UP")
	end
	self:pushUI()
end

-- Loop --------------------------------------------------------------------------------------------

-- Runs forever, one step per tick.
function Game:run()
	self:setState("Idle")
	while true do
		self:step(task.wait(TICK))
	end
end

-- One tick: redraw the LiveBoard, count down, tick the current state, update the HUD if it changed.
function Game:step(dt)
	if self.attract.running then
		self.liveGrid = {} -- the attract demo owns the LiveBoard while it runs
	else
		self.liveGrid = self.liveBoard:render(self.store.get().blocks)
	end
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
	if name ~= "Idle" then
		self.attract:stop() -- cancels its timers and animations and clears both boards
	end
	self.state = name
	self.timerRunning = false
	self.timeLeft = 0
	self.revealPhase, self.revealLeft = nil, nil
	self.events:stop()
	self.liveBoard:showProblems(nil)
	states[name].enter(self)
	log("state %s%s", name, self.mode and name ~= "Idle" and (" (" .. self.mode .. ")") or "")
	self:pushUI()
	self:notify()
end

-- Tells the stateChanged listener (the StateStore stand-in's debugAutoSolve) the state and active ticket.
function Game:notify()
	if self.stateChanged then
		local ticket = self.state == "Shift" and self:activeTicket() or nil
		self.stateChanged:Fire({ state = self.state, mode = self.mode, activeId = ticket and ticket.id or nil,
			target = ticket and ticket.target or nil })
	end
end

function Game:startTimer(s)
	self.timeLeft = seconds(s)
	self.timerRunning = true
end

-- A ticket as the HUD needs it: cells maps "B2" -> { bottom color, top color }.
local function ticketCard(ticket, now)
	local cells = {}
	for cell, tower in pairs(ticket.target) do
		cells[cell] = table.clone(tower)
	end
	return { id = ticket.id, points = ticket.points, blocks = ticket.blocks, age = math.floor(now - ticket.arrivedAt), cells = cells }
end

function Game:payload()
	local event, vanishedCells = self.events:payload()
	local tickets = {}
	for _, ticket in ipairs(self.tickets) do
		table.insert(tickets, ticketCard(ticket, self.shiftElapsed))
	end
	return {
		state = self.state,
		mode = self.mode,
		timeLeft = self.timerRunning and math.ceil(self.timeLeft) or 0,
		score = self.score,
		message = self.message,
		tickets = tickets,             -- oldest first
		activeId = self.activeId,
		railMax = Config.ticketRailMax,
		completedCount = #self.completed,
		completed = table.clone(self.completed), -- { id, points, blocks, stacked, seconds } per completed ticket
		orderUp = self.orderUp,        -- { id, points, bonus, seq } for the latest ORDER UP, or nil
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
	local tickets = {}
	for _, t in ipairs(p.tickets) do
		table.insert(tickets, t.id .. "@" .. t.age)
	end
	return string.format("%d|%s|%s|%s|%s|%s|%s|%s", p.timeLeft, tostring(p.revealPhase), tostring(p.revealTimeLeft),
		event, table.concat(p.vanishedCells, ","), table.concat(tickets, ","), tostring(p.activeId),
		tostring(p.orderUp and p.orderUp.seq))
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
