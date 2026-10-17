-- ReplicatedStorage.Core.StateStore
-- STAND-IN. The core teammate replaces this module with the real StateStore. Kept minimal on purpose:
-- it only provides the API Pattern Match reads.
--   StateStore.get()    -> { blocks = { {id, color, x, y, level, held, visible, zone}, ... }, arm = {} }
--   StateStore.changed  -> signal (BindableEvent.Event) fired after every state update
-- With PatternMatch.Config.useFakeState = true, the server changes one thing every 2 s: it moves, adds
-- or removes a block on the 4x3 grid, or adds/drops one off-grid block or one held block so the game
-- can be seen ignoring those.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)

local StateStore = {}

local state = { blocks = {}, arm = {} }
local changedEvent = Instance.new("BindableEvent")
StateStore.changed = changedEvent.Event

function StateStore.get()
	return state
end

-- Fake mode ---------------------------------------------------------------

local FAKE_INTERVAL = 2
local FAKE_JITTER_CM = 0.5
local FAKE_MAX_GRID_BLOCKS = 8

local rng = Random.new()
local nextId = 1
local fakeCell = {} -- block id -> "B2" for on-grid fake blocks, "offgrid" or "held" for the others

local function cellLabel(col, row)
	return string.char(64 + col) .. row
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

local function newBlock(x, y, held, tag)
	local block = {
		id = "fake" .. nextId,
		color = randomColor(),
		x = x, y = y, level = 0,
		held = held, visible = true, zone = "table",
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
			local block = newBlock(x, y, false, cell)
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
		-- Either half a cell past the right edge of the grid, or right on a boundary between two columns.
		local _, y = cellCenterCm(1, rng:NextInteger(1, Config.gridRows))
		local x = Config.gridOriginCm.X + Config.cellSizeCm * (rng:NextNumber() < 0.5
			and Config.gridCols + 0.5
			or rng:NextInteger(1, Config.gridCols - 1))
		local block = newBlock(x, y, false, "offgrid")
		table.insert(blocks, block)
		msg = string.format("add off-grid %s %s at (%.1f, %.1f) cm", block.id, block.color, x, y)
	elseif held then
		local block = table.remove(blocks, held)
		msg = "drop held " .. block.id
		fakeCell[block.id] = nil
	else
		local col, row = rng:NextInteger(1, Config.gridCols), rng:NextInteger(1, Config.gridRows)
		local x, y = cellCenterCm(col, row)
		local block = newBlock(x, y, true, "held")
		table.insert(blocks, block)
		msg = string.format("add held %s %s over %s", block.id, block.color, cellLabel(col, row))
	end

	state = { blocks = blocks, arm = state.arm }
	return msg
end

if Config.useFakeState and RunService:IsServer() and RunService:IsRunning() then
	task.spawn(function()
		while true do
			task.wait(FAKE_INTERVAL)
			print("[StateStore fake] " .. fakeStep())
			changedEvent:Fire(state)
		end
	end)
end

return StateStore
