-- ReplicatedStorage.Core.StateStore
-- Pattern Match's view of the robot: a thin adapter over the core's ServerScriptService.Bridge, which owns
-- the one WebSocket (PROTOCOL.md). The live parts run on the server only; clients get the arm twin and
-- the HUD status through PatternMatch remotes, never from here.
--   StateStore.get()       -> latest state: { t = "state", seq, ts, arm, blocks, blocks_age }
--                             arm = { joints = { shoulder_pan = deg, ... }, points = { {name, x, y, z}, ... } }
--                             (points base to tip, sheet mm), or nil while there is no arm data;
--                             blocks = { {id, color, x, y, z, yaw, level, held, visible}, ... } in sheet mm,
--                             colors mapped to Config.colors names (Config.perceptionColors); any other
--                             name is kept as sent, and the game treats it as a misread.
--   StateStore.update(msg) -> store a new state message and fire changed (the fake generator and tests)
--   StateStore.changed     -> signal (BindableEvent.Event) fired after every state update
--   StateStore.source()    -> "pending" (waiting for the hello), "bridge" or "fake"
--   StateStore.status()    -> "live" (bridge, any source but mock), "mock" (bridge, source mock),
--                             "offline" (see linkStatus, or still pending) or "fake" (fake generator)
--   StateStore.linkStatus(helloSource, sinceFrame, blocksAge, armAge) -> "live" | "mock" | "offline",
--                             the bridge part of status() as a pure function; the server also keeps
--                             status() in the "RobotLink" attribute of ReplicatedStorage.Core, for any client
--   StateStore.hello()    -> the bridge's hello frame, or nil
--   StateStore.sendEvent(name, intensity, duration) -> true if it went to the robot, else false, reason
--
-- Bridge mode (Config.useBridge, the default): the server requires ServerScriptService.Bridge, registers
-- onHello / onState and calls Bridge.connect once. Bridge keeps only the newest frame and hands it over on
-- Heartbeat; this module converts it and keeps it. The hello's space.grid goes to Grid.setGeometry.
-- No hello within Config.bridgeHelloSeconds of server start (or useBridge = false, or no Bridge module):
-- the fake generator runs instead. That is decided once: after the bridge has said hello, a dropped link
-- is just OFFLINE (the game freezes matching) and never falls back to fake data. A hello that arrives
-- after the fake took over switches to the bridge, but never in the middle of a shift.
--
-- Fake generator: publishes a fake arm (small waves around the twin's rest pose, as sheet-mm points from
-- ArmTwin.Rig) 20 times a second. Blocks only change through the Debug hook below or debugAutoSolve
-- (no random placements: the idle board is Pattern Match's attract-mode demo, which never writes here).
-- With Config.debugAutoSolve also on (fake generator, or the bridge's mock source for testing: the solved
-- board then replaces the mock's blocks until the game leaves the shift), it follows the Pattern Match
-- game (PatternMatch.Remotes.PatternState):
-- 3 s after each ticket becomes active the board is rebuilt to
-- match it, reusing the blocks already there (rebuiltBlocks; leftovers go to the tray). The delay
-- ignores debugFastTimers.
-- In fake mode a server-only BindableEvent StateStore.Debug takes test commands (see debugCommand).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)
local Grid = require(ReplicatedStorage.PatternMatch.Grid)

local StateStore = {}

local state = {
	t = "state", seq = 0, ts = 0,
	arm = nil, -- no arm data yet: the arm twin shows its rest pose
	blocks = {},
}
local changedEvent = Instance.new("BindableEvent")
StateStore.changed = changedEvent.Event

local source = "pending" -- "pending" | "bridge" | "fake"
local bridge = nil       -- the core's Bridge module, once required
local helloFrame = nil
local lastFrameAt = nil  -- os.clock() of the last bridge state frame

function StateStore.get()
	return state
end

function StateStore.update(msg)
	state = msg
	changedEvent:Fire(state)
end

function StateStore.source()
	return source
end

function StateStore.hello()
	return helloFrame
end

-- The bridge link: "offline" when there is no frame yet (sinceFrame nil), none for
-- Config.bridgeStaleSeconds, blocks_age over that, or either age null (the server sends null until
-- that part has published once: teleop without --vision never publishes blocks). Otherwise "mock" for
-- hello source "mock" and "live" for any other source (teleop, follower, auto, anything new, or none).
function StateStore.linkStatus(helloSource, sinceFrame, blocksAge, armAge)
	local stale = Config.bridgeStaleSeconds
	blocksAge, armAge = tonumber(blocksAge), tonumber(armAge)
	if type(sinceFrame) ~= "number" or sinceFrame > stale or blocksAge == nil or blocksAge > stale or armAge == nil then
		return "offline"
	end
	return helloSource == "mock" and "mock" or "live"
end

function StateStore.status()
	if source == "fake" then
		return "fake"
	end
	if source ~= "bridge" then
		return "offline"
	end
	return StateStore.linkStatus(helloFrame and helloFrame.source, lastFrameAt and os.clock() - lastFrameAt,
		state.blocks_age, state.arm_age)
end

function StateStore.sendEvent(name, intensity, duration)
	if source ~= "bridge" or not bridge then
		return false, "no robot bridge (" .. source .. ")"
	end
	if not (helloFrame and table.find(helloFrame.effects or {}, name)) then
		return false, "not in hello.effects"
	end
	if not bridge.sendEvent(name, intensity, duration) then
		return false, "link down"
	end
	return true
end

-- Bridge frames -> state ---------------------------------------------------------------------------

local unknownColors = {} -- protocol color names with no Config.colors entry, warned about once each

-- A perception color name as a Config.colors name, through Config.perceptionColors ("light blue" ->
-- "skyblue"). Any other name is a misread (our kit has only the six): it is kept as sent, so the LiveBoard
-- draws it gray and Target.compare counts it as a wrong block (Target.isMisread).
function StateStore.colorName(name)
	local mapped = Config.perceptionColors[name]
	if mapped then
		return mapped
	end
	if not unknownColors[name] then
		unknownColors[name] = true
		warn(string.format("[StateStore] misread block color %q (not one of our six): shown gray, never matches", tostring(name)))
	end
	return name
end

-- A bridge state frame -> this module's state (blocks copied, colors mapped).
function StateStore.fromFrame(frame)
	local blocks = {}
	for _, b in ipairs(frame.blocks or {}) do
		local block = table.clone(b)
		-- A held block reports "grey" (PROTOCOL.md). It never counts, so it isn't mapped or warned about.
		block.color = b.held and b.color or StateStore.colorName(b.color)
		table.insert(blocks, block)
	end
	local arm = frame.arm
	if type(arm) ~= "table" or type(arm.points) ~= "table" or #arm.points == 0 then
		arm = nil
	end
	return {
		t = "state", seq = frame.seq, ts = frame.ts,
		arm = arm, arm_age = frame.arm_age, blocks = blocks, blocks_age = frame.blocks_age, effects = frame.effects,
	}
end

-- Fake generator ----------------------------------------------------------------------------------

local FAKE_JITTER_MM = 5
local FAKE_HELD_Z_MM = 80
local FAKE_BLOCK_MM = 48 -- the real cube: a level n block reports z = n * this

local rng = Random.new()
local nextId = 10 -- block ids are ArUco marker ids, 10 and up
local fakeCell = {} -- block id -> "B2" for on-grid fake blocks, "offgrid" or "held" for the others

local function cellCenterMm(col, row)
	local g = Grid.geometry()
	return g.originX + (col - 0.5) * g.cell, g.originY + (row - 0.5) * g.cell
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
		x = x, y = y, z = held and FAKE_HELD_Z_MM or level * FAKE_BLOCK_MM, yaw = rng:NextInteger(0, 89),
		level = level, held = held, visible = not held, zone = "play",
	}
	nextId += 1
	fakeCell[block.id] = tag
	return block
end

-- Stores a new state message around the given block list (and arm, else the current one; arm = false
-- stores no arm data).
local function publish(blocks, arm)
	if arm == false then
		arm = nil
	else
		arm = arm or state.arm
	end
	StateStore.update({
		t = "state", seq = state.seq + 1, ts = DateTime.now().UnixTimestampMillis / 1000,
		arm = arm, arm_age = arm and 0 or nil, blocks = blocks, blocks_age = 0, -- fake data is always fresh
	})
end

-- Fake arm: an idle arm near Config.twinRestPose (degrees, gripper 0..100). Small slow sine waves at
-- different speeds; the elbow takes back the shoulder's wave and the wrist the elbow's, so the forearm
-- stays about level and the hand hangs in front of the base (twin stays under ~17 studs above its base,
-- hand clear of the base and table). The gripper opens and closes between 10 and 60. The Debug "arm"
-- command replaces it with a fixed pose or with no arm data.
local FAKE_ARM_HZ = 20
local fixedArm = nil -- Debug: a held pose, or false for no arm data
local function fakeAngles(t)
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

-- Joint angles -> the arm as the bridge sends it: { joints, points }, points in sheet mm base to tip, from
-- ArmTwin.Rig's forward kinematics. The fake base stands where the built twin does: centered on the grid's
-- width, Config.twinBaseOffsetMm before row A. Rig frame -> sheet: rig -Z (forward, toward the board) is
-- +y, rig +X (the twin's right: column 1's side) is -x, rig +Y is z.
function StateStore.fakeArm(angles)
	local twin = ReplicatedStorage:FindFirstChild("ArmTwin")
	if not (twin and twin:FindFirstChild("Rig") and twin:FindFirstChild("Driver")) then
		return nil
	end
	local Rig = require(twin.Rig)
	local Driver = require(twin.Driver)
	local g = Grid.geometry()
	local bx, by = g.originX + g.cols * g.cell / 2, g.originY - Config.twinBaseOffsetMm
	local points = {}
	for i, p in ipairs(Rig.chainPoints(Driver.rigAngles(Driver.withRest(angles)), true)) do
		points[i] = { name = Rig.POINT_NAMES[i], x = bx - p.X * 10, y = by - p.Z * 10, z = p.Y * 10 }
	end
	return { joints = table.clone(angles), points = points }
end

local AUTO_SOLVE_DELAY = 3 -- debugAutoSolve: seconds after a ticket becomes active (ignores debugFastTimers)
local mockSolved = nil      -- debugAutoSolve on the mock link: the solved blocks shown instead of the mock's
local FAKE_TRAY_MAX = 8     -- blocks the fake tray keeps; extras beyond this are taken off the table

local function cellOfLabel(cell)
	return string.byte(cell) - 64, tonumber(string.sub(cell, 2)) -- row, col
end

-- The current blocks rearranged so the grid matches `target` exactly, reusing what is already there, the
-- way a player would: a block already at the right cell and level in the right color stays put; every
-- other needed block is taken from the unused blocks of that color (wrong spot on the grid, the tray, or
-- held) and moved; anything still missing is added; leftover blocks go to the tray (zone "tray", which
-- the game ignores). Towers get matching level values.
local function rebuiltBlocks(target, from)
	local need = {} -- "B2:1" -> color, for every target cell and level
	for cell, tower in pairs(target) do
		for i, color in ipairs(tower) do
			need[cell .. ":" .. (i - 1)] = color
		end
	end

	local kept, pool = {}, {}
	for _, block in ipairs(from or state.blocks) do
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
		local cx, cy = cellCenterMm(col, row)
		local x = cx + rng:NextNumber(-FAKE_JITTER_MM, FAKE_JITTER_MM)
		local y = cy + rng:NextNumber(-FAKE_JITTER_MM, FAKE_JITTER_MM)
		local reuse = nil
		for i, block in ipairs(pool) do
			if block.color == color then
				reuse = table.remove(pool, i)
				break
			end
		end
		if reuse then
			local block = table.clone(reuse)
			block.x, block.y, block.z, block.level = x, y, level * FAKE_BLOCK_MM, level
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
	local g = Grid.geometry()
	local trayX = g.originX + g.cell * (g.cols + 0.5)
	for i, leftover in ipairs(pool) do
		if i > FAKE_TRAY_MAX then
			fakeCell[leftover.id] = nil
		else
			local block = table.clone(leftover)
			local _, y = cellCenterMm(1, (i - 1) % g.rows + 1)
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
local gameState = nil         -- the Pattern Match state ("Idle", "Shift", ...)
local onGameState = nil       -- set below: called with each new game state

-- Follows the Pattern Match game (PatternMatch.Remotes.PatternState, fired on every state change and
-- every active ticket change): keeps the state and the active ticket's target, and with
-- Config.debugAutoSolve (fake generator, or the mock source) rebuilds the board for it AUTO_SOLVE_DELAY
-- seconds after it becomes active.
local function followGame()
	local stateSignal = ReplicatedStorage.PatternMatch:WaitForChild("Remotes"):WaitForChild("PatternState")
	local generation = 0
	stateSignal.Event:Connect(function(info)
		generation += 1
		local mine = generation
		currentTarget = info.target
		gameState = info.state
		if onGameState then
			onGameState(info.state)
		end
		if info.state ~= "Shift" then
			mockSolved = nil -- the mock's own blocks again
		end
		local mock = source == "bridge" and helloFrame ~= nil and helloFrame.source == "mock"
		if not Config.debugAutoSolve or (source ~= "fake" and not mock) then
			return
		end
		if info.state == "Shift" and info.target then
			task.delay(AUTO_SOLVE_DELAY, function()
				if generation ~= mine then
					return
				end
				if source == "fake" then
					local blocks, note = rebuiltBlocks(info.target)
					publish(blocks)
					print(string.format("[StateStore fake] debugAutoSolve: rebuilt the board for ticket #%s (%s)", tostring(info.activeId), note))
				elseif mock then
					local blocks, note = rebuiltBlocks(info.target, mockSolved or {})
					mockSolved = blocks
					print(string.format("[StateStore mock] debugAutoSolve: board solved for ticket #%s over the mock's blocks (%s)", tostring(info.activeId), note))
				end
			end)
		end
	end)
end

-- Testing hook, server only, fake generator only: ReplicatedStorage.Core.StateStore.Debug:Fire(command) with
--   { op = "add", cell = "B2", color = "red", level = 1 } add a block at that cell's center, at the given
--                                              stack level (default 0, the table)
--   { op = "remove", cell = "B2" }             remove the fake blocks on that cell, every level
--   { op = "solve" }                           rebuild the board for the active ticket (reusing blocks)
--   { op = "arm", angles = { shoulder_pan = 0, ... } }  hold the fake arm at exact joint angles (degrees,
--                                              gripper 0..100; joints left out show their rest values);
--                                              angles = nil goes back to the sine waves
--   { op = "arm", off = true }                 stop sending arm data (state.arm = nil): the twin eases
--                                              back to its rest pose after the client's stale timeout
local function debugCommand(cmd)
	if source ~= "fake" then
		return
	end
	if cmd.op == "arm" then
		if cmd.off then
			fixedArm = false
		else
			fixedArm = cmd.angles
		end
	elseif cmd.op == "add" then
		local row, col = string.byte(cmd.cell) - 64, tonumber(string.sub(cmd.cell, 2))
		local x, y = cellCenterMm(col, row)
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

-- Starting up -------------------------------------------------------------------------------------

local function startFake(why)
	if source ~= "pending" then
		return
	end
	source = "fake"
	print("[StateStore] fake generator on: " .. why)
	local debugEvent = Instance.new("BindableEvent")
	debugEvent.Name = "Debug"
	debugEvent.Event:Connect(debugCommand)
	debugEvent.Parent = script
	task.spawn(function()
		local started = os.clock()
		while source == "fake" do
			if fixedArm == false then
				publish(state.blocks, false)
			else
				publish(state.blocks, StateStore.fakeArm(fixedArm or fakeAngles(os.clock() - started)))
			end
			task.wait(1 / FAKE_ARM_HZ)
		end
	end)
end

local switchLater = false -- a hello came while the fake ran mid-shift: switch once the shift is over

local function switchToBridge()
	switchLater = false
	local wasFake = source == "fake"
	source = "bridge"
	if wasFake then
		local debugEvent = script:FindFirstChild("Debug")
		if debugEvent then
			debugEvent:Destroy()
		end
		table.clear(fakeCell)
		StateStore.update({ t = "state", seq = 0, ts = 0, arm = nil, blocks = {} })
		print("[StateStore] the bridge said hello: fake generator off, using the robot")
	end
end

onGameState = function(newState)
	if switchLater and newState ~= "Shift" then
		switchToBridge()
	end
end

local function onHello(h)
	helloFrame = h
	local warning = Grid.setGeometry(h.space and h.space.grid)
	local g = Grid.geometry()
	print(string.format("[StateStore] hello: source=%s, grid origin (%.3f, %.3f) mm, cell %.3f mm, %dx%d, effects %s",
		tostring(h.source), g.originX, g.originY, g.cell, g.rows, g.cols, table.concat(h.effects or {}, ",")))
	if warning then
		warn("[StateStore] " .. warning)
	end
	if source == "fake" and gameState == "Shift" then
		switchLater = true
		print("[StateStore] hello mid-shift: the fake generator keeps the board until the shift ends")
		return
	end
	switchToBridge()
end

local function onState(frame)
	if source ~= "bridge" then
		return
	end
	lastFrameAt = os.clock()
	local converted = StateStore.fromFrame(frame)
	if mockSolved and Config.debugAutoSolve then
		converted.blocks, converted.blocks_age = mockSolved, 0 -- testing on the mock: the auto-solved board
	end
	StateStore.update(converted)
end

if RunService:IsServer() and RunService:IsRunning() then
	task.spawn(followGame)
	task.spawn(function() -- the link status for every client (the lobby robot view's badge)
		while true do
			local status = StateStore.status()
			if script.Parent:GetAttribute("RobotLink") ~= status then
				script.Parent:SetAttribute("RobotLink", status)
			end
			task.wait(0.25)
		end
	end)
	if not Config.useBridge then
		startFake("Config.useBridge is false")
	else
		local module = game:GetService("ServerScriptService"):WaitForChild("Bridge", 5)
		local ok, result = false, "ServerScriptService.Bridge is missing"
		if module then
			ok, result = pcall(require, module)
		end
		if not ok then
			warn("[StateStore] " .. tostring(result))
			startFake("no Bridge module")
		else
			bridge = result
			bridge.onHello(onHello)
			bridge.onState(onState)
			bridge.connect(Config.bridgeUrl)
			task.delay(Config.bridgeHelloSeconds, function()
				if helloFrame == nil then
					startFake(string.format("no hello from %s within %d s", Config.bridgeUrl, Config.bridgeHelloSeconds))
				end
			end)
		end
	end
end

return StateStore
