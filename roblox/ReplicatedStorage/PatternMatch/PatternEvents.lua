-- ReplicatedStorage.PatternMatch.PatternEvents
-- Pattern Match events (spec section 4): the scheduler and the event implementations.
-- PatternMatch.Game owns one and drives it: startRound when a round starts, tick every 0.2 s during
-- the round, stopRound when it ends. So events only ever run inside a Round.
--   vanish   - 1-2 empty non-target LiveBoard tiles turn invisible for Config.vanishSeconds (Roblox only)
--   tremor   - both boards shake and clients shake their camera; Core.Events.fire("earthquake", 0.5, 4)
--   inverted - "ARM INVERTED" banner; Core.Events.fire("mirror", 1, 8)
-- The first event runs one interval into the round (Config.easy/hard.eventEvery, or debugEventEvery),
-- then one every interval. Each shows a 2 s warning banner first. One event at a time, and never the
-- same event twice in a row.

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local WARNING_SECONDS = 2
local SHAKE_STUDS = 0.15
local SHAKE_RADIANS = math.rad(1)

local SPECS = {
	vanish = { banner = "TILES VANISHING", seconds = function() return Config.vanishSeconds end },
	tremor = { banner = "TREMOR", seconds = function() return 4 end, core = { "earthquake", 0.5, 4 } },
	inverted = { banner = "ARM INVERTED", seconds = function() return 8 end, core = { "mirror", 1, 8 } },
}

local PatternEvents = {}
PatternEvents.__index = PatternEvents
PatternEvents.SPECS = SPECS
PatternEvents.WARNING_SECONDS = WARNING_SECONDS

-- A timer length from Config, in seconds, 4x shorter when Config.debugFastTimers is on.
local function seconds(s)
	return Config.debugFastTimers and s / 4 or s
end

local function log(fmt, ...)
	print("[PatternEvents] " .. string.format(fmt, ...))
end

-- Up to `count` random cells that need no block (not in target), have no counted block on them (not in
-- liveGrid) and aren't vanished already. Empty when nothing qualifies.
function PatternEvents.pickVanishCells(target, liveGrid, vanished, count, rng)
	local candidates = {}
	for _, cell in ipairs(Grid.allCells()) do
		if target[cell] == nil and liveGrid[cell] == nil and not vanished[cell] then
			table.insert(candidates, cell)
		end
	end
	local picked = {}
	for _ = 1, math.min(count, #candidates) do
		table.insert(picked, table.remove(candidates, rng:NextInteger(1, #candidates)))
	end
	table.sort(picked)
	return picked
end

-- opts: core (Core.Events), liveBoard (LiveBoard object), boards (Models that shake), rng (optional Random)
function PatternEvents.new(opts)
	local self = setmetatable({}, PatternEvents)
	self.core = opts.core
	self.liveBoard = opts.liveBoard
	self.boards = opts.boards or {}
	self.rng = opts.rng or Random.new()
	self.running = false
	self.current = nil -- { name, phase = "warning" | "active", timeLeft, cells }
	self.last = nil    -- the last event that actually ran
	self.vanished = {} -- cell -> true while the tile is invisible
	self.sticky = {}   -- cell -> true: its vanish timer ran out with a block on it; back once the block goes
	return self
end

-- A round starts: clear everything and schedule the first event one interval in.
function PatternEvents:startRound(mode)
	self:stopRound()
	local every = Config.debugEventEvery or (mode == "Hard" and Config.hard.eventEvery or Config.easy.eventEvery)
	self.running = true
	self.elapsed = 0
	self.every = seconds(every)
	self.nextAt = self.every -- when the next event runs; its warning starts WARNING_SECONDS earlier
end

-- The round is over: end any event, restore the boards, schedule nothing.
function PatternEvents:stopRound()
	self.running = false
	self.current = nil
	self:stopShake()
	table.clear(self.vanished)
	table.clear(self.sticky)
	if self.liveBoard then
		self.liveBoard:setVanished(self.vanished)
	end
end

-- One round tick. target and liveGrid are the round's target and the live grid just drawn.
function PatternEvents:tick(dt, target, liveGrid)
	if not self.running then
		return
	end
	self.elapsed += dt

	for cell in pairs(self.sticky) do
		if liveGrid[cell] == nil then
			self.sticky[cell] = nil
			self.vanished[cell] = nil
		end
	end

	local event = self.current
	if event then
		event.timeLeft -= dt
		if event.timeLeft <= 0 then
			if event.phase == "warning" then
				self:begin(event, target, liveGrid)
			else
				self:finish(event, liveGrid)
			end
		end
	end
	if not self.current and self.elapsed >= self.nextAt - seconds(WARNING_SECONDS) then
		self.nextAt += self.every
		self:warn(target, liveGrid)
	end

	if self.liveBoard then
		self.liveBoard:setVanished(self.vanished)
	end
end

-- Random enabled event, never the one that ran last (unless it's the only one enabled).
function PatternEvents:pick()
	local options = {}
	for _, name in ipairs(Config.events) do
		if SPECS[name] and name ~= self.last then
			table.insert(options, name)
		end
	end
	if #options == 0 and self.last and table.find(Config.events, self.last) then
		options = { self.last }
	end
	if #options == 0 then
		return nil
	end
	return options[self.rng:NextInteger(1, #options)]
end

function PatternEvents:warn(target, liveGrid)
	local name = self:pick()
	if not name then
		return
	end
	local event = { name = name, phase = "warning", timeLeft = seconds(WARNING_SECONDS) }
	if name == "vanish" then
		local count = self.rng:NextInteger(Config.vanishCount[1], Config.vanishCount[2])
		event.cells = PatternEvents.pickVanishCells(target, liveGrid, self.vanished, count, self.rng)
		if #event.cells == 0 then
			log("vanish skipped: no empty non-target cell")
			return
		end
	end
	self.current = event
	log("warning: %s", name)
end

function PatternEvents:begin(event, target, liveGrid)
	local spec = SPECS[event.name]
	if event.name == "vanish" then
		-- A block may have landed on a picked cell during the warning; vanish only the ones still empty.
		local cells = {}
		for _, cell in ipairs(event.cells) do
			if liveGrid[cell] == nil and target[cell] == nil then
				table.insert(cells, cell)
				self.vanished[cell] = true
			end
		end
		event.cells = cells
		if #cells == 0 then
			self.current = nil
			log("vanish skipped: its cells filled up during the warning")
			return
		end
	elseif event.name == "tremor" then
		self:startShake()
	end
	if spec.core then
		self.core.fire(spec.core[1], spec.core[2], spec.core[3])
	end
	event.phase = "active"
	event.timeLeft = seconds(spec.seconds())
	self.last = event.name
	log("start %s%s", event.name, event.cells and (" " .. table.concat(event.cells, ",")) or "")
end

function PatternEvents:finish(event, liveGrid)
	if event.name == "vanish" then
		for _, cell in ipairs(event.cells) do
			if liveGrid[cell] ~= nil then
				self.sticky[cell] = true -- stays vanished, and blocks the round, until its block is removed
			else
				self.vanished[cell] = nil
			end
		end
	elseif event.name == "tremor" then
		self:stopShake()
	end
	self.current = nil
	log("end %s", event.name)
end

-- Shakes the boards every frame until stopShake, which puts every part back exactly where it was.
function PatternEvents:startShake()
	self:stopShake()
	local saved, pivots = {}, {}
	for _, board in ipairs(self.boards) do
		pivots[board] = board:GetPivot()
		for _, part in ipairs(board:GetDescendants()) do
			if part:IsA("BasePart") then
				saved[part] = part.CFrame
			end
		end
	end
	local rng = self.rng
	local connection = RunService.Heartbeat:Connect(function()
		for board, pivot in pairs(pivots) do
			local offset = CFrame.new(rng:NextNumber(-SHAKE_STUDS, SHAKE_STUDS), 0, rng:NextNumber(-SHAKE_STUDS, SHAKE_STUDS))
				* CFrame.Angles(0, rng:NextNumber(-SHAKE_RADIANS, SHAKE_RADIANS), 0)
			board:PivotTo(pivot * offset)
		end
	end)
	self.shake = { saved = saved, connection = connection }
end

function PatternEvents:stopShake()
	local shake = self.shake
	if not shake then
		return
	end
	shake.connection:Disconnect()
	for part, cframe in pairs(shake.saved) do
		part.CFrame = cframe
	end
	self.shake = nil
end

-- HUD fields: event = { name, banner, phase, timeLeft } or nil, and the sorted vanished cells.
function PatternEvents:payload()
	local event
	if self.current then
		event = {
			name = self.current.name,
			banner = SPECS[self.current.name].banner,
			phase = self.current.phase,
			timeLeft = math.ceil(self.current.timeLeft),
		}
	end
	local cells = {}
	for cell in pairs(self.vanished) do
		table.insert(cells, cell)
	end
	table.sort(cells)
	return event, cells
end

return PatternEvents
