-- ReplicatedStorage.Core.StateStore
-- STAND-IN. The core teammate replaces this module with the real StateStore. Kept minimal on purpose:
-- it only provides the API Pattern Match reads.
--   StateStore.get()       -> latest state message, shaped like plan.md section 2:
--                             { t = "state", seq, ts, arm = { shoulder_pan = deg, ... }, tip = {x, y, z},
--                               blocks = { {id = number, color, x, y, z, yaw, level, held, visible, zone}, ... } }
--                             Table cm: origin at corner marker 0, x across, y away from the operator, z up.
--   StateStore.update(msg) -> store a new state message (what the Bridge calls) and fire changed
--   StateStore.changed     -> signal (BindableEvent.Event) fired after every state update
-- With PatternMatch.Config.useFakeState = true, the server changes one thing every 2 s: it moves, adds
-- or removes a block on the 4x3 grid, or adds/drops one off-grid block (in the tray, or on a cell
-- boundary) or one held block so the game can be seen ignoring those.
-- With Config.debugAutoSolve also on, it follows the Pattern Match game (PatternMatch.Remotes.PatternState):
-- no random changes during a round or intermission, the exact target appears 5 s into each round, and
-- the grid empties 3 s into each intermission. These two delays ignore debugFastTimers.
-- In fake mode a server-only BindableEvent StateStore.Debug takes test commands (see debugCommand).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)

local StateStore = {}

local state = {
	t = "state", seq = 0, ts = 0,
	arm = { shoulder_pan = 0, shoulder_lift = 0, elbow_flex = 0, wrist_flex = 0, wrist_roll = 0, gripper = 0 },
	tip = { x = 0, y = 0, z = 0 },
	blocks = {},
}
local changedEvent = Instance.new("BindableEvent")
StateStore.changed = changedEvent.Event

function StateStore.get()
	return state
end

function StateStore.update(msg)
	state = msg
	changedEvent:Fire(state)
end

-- Fake mode ---------------------------------------------------------------

local FAKE_INTERVAL = 2
local FAKE_JITTER_CM = 0.5
local FAKE_MAX_GRID_BLOCKS = 8
local FAKE_HELD_Z_CM = 8

local rng = Random.new()
local nextId = 10 -- block ids are ArUco marker ids, 10 and up
local fakeCell = {} -- block id -> "B2" for on-grid fake blocks, "offgrid" or "held" for the others

-- Cell names match the printed sheet: row letter A-C, then column number 1-4.
local function cellLabel(col, row)
	return string.char(64 + row) .. col
end

local function cellCenterCm(col, row)
	local size = Config.cellSizeCm
	return Config.gridOriginCm.X + (col - 0.5) * size, Config.gridOriginCm.Y + (row - 0.5) * size
end

local function randomColor()
	local names = {}
	for name in pairs(Config.colors) do
		table.insert(names, name)
	end
	table.sort(names)
	return names[rng:NextInteger(1, #names)]
end

-- A held block sits at the gripper tip with its marker covered, like the real world model reports it.
local function newBlock(x, y, tag, color)
	local held = tag == "held"
	local block = {
		id = nextId,
		color = color or randomColor(),
		x = x, y = y, z = held and FAKE_HELD_Z_CM or 0, yaw = rng:NextInteger(0, 89),
		level = 0, held = held, visible = not held, zone = "play",
	}
	nextId += 1
	fakeCell[block.id] = tag
	return block
end

local function pick(list)
	return list[rng:NextInteger(1, #list)]
end

local function fakeStep()
	local blocks = table.clone(state.blocks)
	local onGrid, offGrid, held, used = {}, nil, nil, {}
	for i, block in ipairs(blocks) do
		local tag = fakeCell[block.id]
		if tag == "offgrid" then
			offGrid = i
		elseif tag == "held" then
			held = i
		else
			table.insert(onGrid, i)
			used[tag] = true
		end
	end
	local free = {}
	for col = 1, Config.gridCols do
		for row = 1, Config.gridRows do
			if not used[cellLabel(col, row)] then
				table.insert(free, { col, row })
			end
		end
	end

	local choices = { "offgrid", "held" }
	if #free > 0 and #onGrid < FAKE_MAX_GRID_BLOCKS then table.insert(choices, "add"); table.insert(choices, "add") end
	if #onGrid > 0 and #free > 0 then table.insert(choices, "move"); table.insert(choices, "move") end
	if #onGrid > 0 then table.insert(choices, "remove") end
	local action = pick(choices)

	local msg
	if action == "add" or action == "move" then
		local spot = pick(free)
		local cell = cellLabel(spot[1], spot[2])
		local cx, cy = cellCenterCm(spot[1], spot[2])
		local x = cx + rng:NextNumber(-FAKE_JITTER_CM, FAKE_JITTER_CM)
		local y = cy + rng:NextNumber(-FAKE_JITTER_CM, FAKE_JITTER_CM)
		if action == "add" then
			local block = newBlock(x, y, cell)
			table.insert(blocks, block)
			msg = string.format("add %s %s at %s", block.id, block.color, cell)
		else
			local i = pick(onGrid)
			local block = table.clone(blocks[i])
			msg = string.format("move %s %s %s -> %s", block.id, block.color, fakeCell[block.id], cell)
			block.x, block.y = x, y
			fakeCell[block.id] = cell
			blocks[i] = block
		end
	elseif action == "remove" then
		local block = table.remove(blocks, pick(onGrid))
		msg = string.format("remove %s %s from %s", block.id, block.color, fakeCell[block.id])
		fakeCell[block.id] = nil
	elseif action == "offgrid" and offGrid then
		local block = table.remove(blocks, offGrid)
		msg = "remove off-grid " .. block.id
		fakeCell[block.id] = nil
	elseif action == "offgrid" then
		-- Either parked in the tray strip past column 4, or right on a column boundary.
		local inTray = rng:NextNumber() < 0.5
		local _, y = cellCenterCm(1, rng:NextInteger(1, Config.gridRows))
		local x = Config.gridOriginCm.X + Config.cellSizeCm
			* (inTray and Config.gridCols + 0.5 or rng:NextInteger(1, Config.gridCols - 1))
		local block = newBlock(x, y, "offgrid")
		if inTray then
			block.zone = "tray"
		end
		table.insert(blocks, block)
		msg = string.format("add off-grid %s %s at (%.1f, %.1f) cm, zone %s", block.id, block.color, x, y, block.zone)
	elseif held then
		local block = table.remove(blocks, held)
		msg = "drop held " .. block.id
		fakeCell[block.id] = nil
	else
		local col, row = rng:NextInteger(1, Config.gridCols), rng:NextInteger(1, Config.gridRows)
		local x, y = cellCenterCm(col, row)
		local block = newBlock(x, y, "held")
		table.insert(blocks, block)
		msg = string.format("add held %s %s over %s", block.id, block.color, cellLabel(col, row))
	end

	return blocks, msg
end

-- Stores a new state message around the given block list.
local function publish(blocks)
	StateStore.update({
		t = "state", seq = state.seq + 1, ts = DateTime.now().UnixTimestampMillis / 1000,
		arm = state.arm, tip = state.tip, blocks = blocks,
	})
end

-- Blocks at the target's cells (centers plus jitter) in the target's colors.
local function solvedBlocks(target)
	table.clear(fakeCell)
	local blocks = {}
	for cell, color in pairs(target) do
		local row, col = string.byte(cell) - 64, tonumber(string.sub(cell, 2))
		local cx, cy = cellCenterCm(col, row)
		local x = cx + rng:NextNumber(-FAKE_JITTER_CM, FAKE_JITTER_CM)
		local y = cy + rng:NextNumber(-FAKE_JITTER_CM, FAKE_JITTER_CM)
		table.insert(blocks, newBlock(x, y, cell, color))
	end
	return blocks
end

local autoSolvePaused = false -- debugAutoSolve: no random changes while a round or intermission runs
local debugPaused = false     -- set by the Debug hook's "pause" command
local currentTarget = nil     -- the game's current round target, for the Debug hook's "solve"

-- Follows the Pattern Match game (PatternMatch.Remotes.PatternState): keeps the current target, and with
-- Config.debugAutoSolve solves each round and empties the grid in intermission.
local function followGame()
	local stateSignal = ReplicatedStorage.PatternMatch:WaitForChild("Remotes"):WaitForChild("PatternState")
	local generation = 0
	stateSignal.Event:Connect(function(info)
		generation += 1
		local mine = generation
		currentTarget = info.target
		if not Config.debugAutoSolve then
			return
		end
		autoSolvePaused = info.state == "Round" or info.state == "Intermission"
		if info.state == "Round" then
			task.delay(5, function()
				if generation == mine then
					publish(solvedBlocks(info.target))
					print("[StateStore fake] debugAutoSolve: wrote the round " .. info.round .. " target")
				end
			end)
		elseif info.state == "Intermission" then
			task.delay(3, function()
				if generation == mine then
					table.clear(fakeCell)
					publish({})
					print("[StateStore fake] debugAutoSolve: cleared the grid")
				end
			end)
		end
	end)
end

-- Testing hook, server only: ReplicatedStorage.Core.StateStore.Debug:Fire(command) with
--   { op = "pause", on = true | false }        stop or resume the random changes
--   { op = "add", cell = "B2", color = "red" } add a block at that cell's center
--   { op = "remove", cell = "B2" }             remove the fake blocks on that cell
--   { op = "solve" }                           replace every block with the current round's target
local function debugCommand(cmd)
	if cmd.op == "pause" then
		debugPaused = cmd.on ~= false
	elseif cmd.op == "add" then
		local row, col = string.byte(cmd.cell) - 64, tonumber(string.sub(cmd.cell, 2))
		local x, y = cellCenterCm(col, row)
		local blocks = table.clone(state.blocks)
		table.insert(blocks, newBlock(x, y, cmd.cell, cmd.color))
		publish(blocks)
	elseif cmd.op == "remove" then
		local blocks = {}
		for _, block in ipairs(state.blocks) do
			if fakeCell[block.id] == cmd.cell then
				fakeCell[block.id] = nil
			else
				table.insert(blocks, block)
			end
		end
		publish(blocks)
	elseif cmd.op == "solve" and currentTarget then
		publish(solvedBlocks(currentTarget))
	end
	print(string.format("[StateStore fake] debug %s %s %s", cmd.op, cmd.cell or "", cmd.color or tostring(cmd.on or "")))
end

if Config.useFakeState and RunService:IsServer() and RunService:IsRunning() then
	task.spawn(followGame)
	local debugEvent = Instance.new("BindableEvent")
	debugEvent.Name = "Debug"
	debugEvent.Event:Connect(debugCommand)
	debugEvent.Parent = script
	task.spawn(function()
		while true do
			task.wait(FAKE_INTERVAL)
			if not autoSolvePaused and not debugPaused then
				local blocks, msg = fakeStep()
				print("[StateStore fake] " .. msg)
				publish(blocks)
			end
		end
	end)
end

return StateStore
