-- ReplicatedStorage.Core.StateStore
-- STAND-IN. The core teammate replaces this module with the real StateStore. Kept minimal on purpose:
-- it only provides the API Pattern Match reads.
--   StateStore.get()       -> latest state message, shaped like plan.md section 2:
--                             { t = "state", seq, ts, arm = { shoulder_pan = deg, ... }, tip = {x, y, z},
--                               blocks = { {id = number, color, x, y, z, yaw, level, held, visible, zone}, ... } }
--                             Table cm: origin at corner marker 0, x across, y away from the operator, z up.
--                             arm is nil until the arm reports (the arm twin then shows its rest pose).
--   StateStore.update(msg) -> store a new state message (what the Bridge calls) and fire changed
--   StateStore.changed     -> signal (BindableEvent.Event) fired after every state update
-- With PatternMatch.Config.useFakeState = true, the server publishes a fake arm (small waves around the
-- twin's rest pose) 20 times a second. Blocks only change through the Debug hook below or debugAutoSolve
-- (no random placements: the idle board is Pattern Match's attract-mode demo, which never writes here).
-- With Config.debugAutoSolve also on, it follows the Pattern Match game (PatternMatch.Remotes.PatternState):
-- 3 s after each ticket becomes active the board is rebuilt to
-- match it, reusing the blocks already there (rebuiltBlocks; leftovers go to the tray). The delay
-- ignores debugFastTimers.
-- In fake mode a server-only BindableEvent StateStore.Debug takes test commands (see debugCommand).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)

local StateStore = {}

local state = {
	t = "state", seq = 0, ts = 0,
	arm = nil, -- no arm data yet: the arm twin shows Config.twinRestPose (ArmTwin.Driver)
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

local FAKE_JITTER_CM = 0.5
local FAKE_HELD_Z_CM = 8
local FAKE_BLOCK_CM = 3.5 -- block height: a level n block reports z = n * this (plan.md release rule)

local rng = Random.new()
local nextId = 10 -- block ids are ArUco marker ids, 10 and up
local fakeCell = {} -- block id -> "B2" for on-grid fake blocks, "offgrid" or "held" for the others

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
-- level (default 0) is the block's stack level; z follows it.
local function newBlock(x, y, tag, color, level)
	local held = tag == "held"
	level = level or 0
	local block = {
		id = nextId,
		color = color or randomColor(),
		x = x, y = y, z = held and FAKE_HELD_Z_CM or level * FAKE_BLOCK_CM, yaw = rng:NextInteger(0, 89),
		level = level, held = held, visible = not held, zone = "play",
	}
	nextId += 1
	fakeCell[block.id] = tag
	return block
end

-- Stores a new state message around the given block list (and arm angles, else the current ones;
-- arm = false stores no arm data).
local function publish(blocks, arm)
	if arm == false then
		arm = nil
	else
		arm = arm or state.arm
	end
	StateStore.update({
		t = "state", seq = state.seq + 1, ts = DateTime.now().UnixTimestampMillis / 1000,
		arm = arm, tip = state.tip, blocks = blocks,
	})
end

-- Fake arm: an idle arm near Config.twinRestPose (degrees, gripper 0..100). Small slow sine waves at
-- different speeds; the elbow takes back the shoulder's wave and the wrist the elbow's, so the forearm
-- stays about level and the hand hangs in front of the base (twin stays under ~17 studs above its base,
-- hand clear of the base and table). The gripper opens and closes between 10 and 60. The Debug "arm"
-- command replaces it with a fixed pose or with no arm data.
local FAKE_ARM_HZ = 20
local fixedArm = nil -- Debug: a held pose, or false for no arm data
local function fakeArm(t)
	local rest = Config.twinRestPose or {}
	local lift = 4 * math.sin(t * 0.37)
	local elbow = 4 * math.sin(t * 0.61)
	return {
		shoulder_pan = (rest.shoulder_pan or 0) + 15 * math.sin(t * 0.50),
		shoulder_lift = (rest.shoulder_lift or 0) + lift,
		elbow_flex = (rest.elbow_flex or 0) - lift + elbow,
		wrist_flex = (rest.wrist_flex or 0) - elbow + 5 * math.sin(t * 0.83),
		wrist_roll = (rest.wrist_roll or 0) + 25 * math.sin(t * 0.29),
		gripper = 35 + 25 * math.sin(t * 0.97),
	}
end

local AUTO_SOLVE_DELAY = 3 -- debugAutoSolve: seconds after a ticket becomes active (ignores debugFastTimers)
local FAKE_TRAY_MAX = 8     -- blocks the fake tray keeps; extras beyond this are taken off the table

local function cellOfLabel(cell)
	return string.byte(cell) - 64, tonumber(string.sub(cell, 2)) -- row, col
end

-- The current blocks rearranged so the grid matches `target` exactly, reusing what is already there, the
-- way a player would: a block already at the right cell and level in the right color stays put; every
-- other needed block is taken from the unused blocks of that color (wrong spot on the grid, the tray, or
-- held) and moved; anything still missing is added; leftover blocks go to the tray (zone "tray", which
-- the game ignores). Towers get matching level values.
local function rebuiltBlocks(target)
	local need = {} -- "B2:1" -> color, for every target cell and level
	for cell, tower in pairs(target) do
		for i, color in ipairs(tower) do
			need[cell .. ":" .. (i - 1)] = color
		end
	end

	local kept, pool = {}, {}
	for _, block in ipairs(state.blocks) do
		local tag = fakeCell[block.id]
		local key = tag and tag ~= "offgrid" and tag ~= "held" and (tag .. ":" .. (block.level or 0)) or nil
		if key and need[key] == block.color then
			need[key] = nil
			table.insert(kept, block)
		else
			table.insert(pool, block)
		end
	end

	local keys = {}
	for key in pairs(need) do
		table.insert(keys, key)
	end
	table.sort(keys) -- by cell, then level 0 before level 1
	local moved, added = 0, 0
	for _, key in ipairs(keys) do
		local cell, levelText = string.match(key, "^(%w+):(%d+)$")
		local level = tonumber(levelText)
		local color = need[key]
		local row, col = cellOfLabel(cell)
		local cx, cy = cellCenterCm(col, row)
		local x = cx + rng:NextNumber(-FAKE_JITTER_CM, FAKE_JITTER_CM)
		local y = cy + rng:NextNumber(-FAKE_JITTER_CM, FAKE_JITTER_CM)
		local reuse = nil
		for i, block in ipairs(pool) do
			if block.color == color then
				reuse = table.remove(pool, i)
				break
			end
		end
		if reuse then
			local block = table.clone(reuse)
			block.x, block.y, block.z, block.level = x, y, level * FAKE_BLOCK_CM, level
			block.held, block.visible, block.zone = false, true, "play"
			fakeCell[block.id] = cell
			table.insert(kept, block)
			moved += 1
		else
			table.insert(kept, newBlock(x, y, cell, color, level))
			added += 1
		end
	end

	-- Leftovers to the tray strip past column 4 (zone "tray": never counted), up to FAKE_TRAY_MAX.
	local trayX = Config.gridOriginCm.X + Config.cellSizeCm * (Config.gridCols + 0.5)
	for i, leftover in ipairs(pool) do
		if i > FAKE_TRAY_MAX then
			fakeCell[leftover.id] = nil
		else
			local block = table.clone(leftover)
			local _, y = cellCenterCm(1, (i - 1) % Config.gridRows + 1)
			block.x, block.y, block.z, block.level = trayX, y, 0, 0
			block.held, block.visible, block.zone = false, true, "tray"
			fakeCell[block.id] = "offgrid"
			table.insert(kept, block)
		end
	end
	return kept, string.format("kept %d, moved %d, added %d, %d to the tray", #kept - moved - added - math.min(#pool, FAKE_TRAY_MAX),
		moved, added, math.min(#pool, FAKE_TRAY_MAX))
end

local currentTarget = nil     -- the game's active ticket target, for the Debug hook's "solve"

-- Follows the Pattern Match game (PatternMatch.Remotes.PatternState, fired on every state change and
-- every active ticket change): keeps the active ticket's target, and with Config.debugAutoSolve rebuilds
-- the board for it AUTO_SOLVE_DELAY seconds after it becomes active.
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
		if info.state == "Shift" and info.target then
			task.delay(AUTO_SOLVE_DELAY, function()
				if generation == mine then
					local blocks, note = rebuiltBlocks(info.target)
					publish(blocks)
					print(string.format("[StateStore fake] debugAutoSolve: rebuilt the board for ticket #%s (%s)", tostring(info.activeId), note))
				end
			end)
		end
	end)
end

-- Testing hook, server only: ReplicatedStorage.Core.StateStore.Debug:Fire(command) with
--   { op = "add", cell = "B2", color = "red", level = 1 } add a block at that cell's center, at the given
--                                              stack level (default 0, the table)
--   { op = "remove", cell = "B2" }             remove the fake blocks on that cell, every level
--   { op = "solve" }                           rebuild the board for the active ticket (reusing blocks)
--   { op = "arm", angles = { shoulder_pan = 0, ... } }  hold the fake arm at exact joint angles (degrees,
--                                              gripper 0..100; joints left out show their rest values);
--                                              angles = nil goes back to the sine waves
--   { op = "arm", off = true }                 stop sending arm data (state.arm = nil): the twin eases
--                                              back to its rest pose after ArmTwin.Driver's stale timeout
local function debugCommand(cmd)
	if cmd.op == "arm" then
		if cmd.off then
			fixedArm = false
		else
			fixedArm = cmd.angles
		end
	elseif cmd.op == "add" then
		local row, col = string.byte(cmd.cell) - 64, tonumber(string.sub(cmd.cell, 2))
		local x, y = cellCenterCm(col, row)
		local blocks = table.clone(state.blocks)
		table.insert(blocks, newBlock(x, y, cmd.cell, cmd.color, cmd.level))
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
		publish((rebuiltBlocks(currentTarget)))
	end
	print(string.format("[StateStore fake] debug %s %s %s%s", cmd.op, cmd.cell or "", cmd.color or tostring(cmd.on or ""),
		cmd.level and (" level " .. cmd.level) or ""))
end

if Config.useFakeState and RunService:IsServer() and RunService:IsRunning() then
	task.spawn(followGame)
	local debugEvent = Instance.new("BindableEvent")
	debugEvent.Name = "Debug"
	debugEvent.Event:Connect(debugCommand)
	debugEvent.Parent = script
	task.spawn(function()
		local started = os.clock()
		while true do
			task.wait(1 / FAKE_ARM_HZ)
			if fixedArm == false then
				publish(state.blocks, false)
			else
				publish(state.blocks, fixedArm or fakeArm(os.clock() - started))
			end
		end
	end)
end

return StateStore
