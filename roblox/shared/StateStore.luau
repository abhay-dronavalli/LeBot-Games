-- Studio location: ServerStorage.Shared.StateStore (ModuleScript)
--[[
	The arcade's view of the robot, shared by ArcadeManager and every arcade mode. A thin wrapper over
	the core's ReplicatedStorage.Core.StateStore, which owns the one robot link (the core's
	ServerScriptService.Bridge, URL = ReplicatedStorage.PatternMatch.Config.bridgeUrl). Requiring this
	module requires Core.StateStore, which is what connects on the server; nothing here opens a socket.
	Games read with StateStore.get() or listen on StateStore.Updated (disconnect in Stop()).

	State shape (arcade units; the core keeps sheet mm):
	  arm    = {shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper}  -- degrees, gripper 0-100,
	           or nil while the core has no arm data
	  tip    = {x, y, z}       -- jaw tips in sheet cm, or nil
	  blocks = list of the core's blocks (every core field kept) where
	             x, y, z            are sheet cm (the core's mm / 10; the mm values stay in x_mm, y_mm, z_mm)
	             cell               "A1".."C4" from the core Grid (Grid.cellOfBlock, in mm), nil when the block
	                                is off the grid, between cells, held, stale or in an ignored zone
	  tower  = number          -- always 0: the core sends no tower count (Rising Flood reads cells)
	  seq, ts                  -- the core frame's

	StateStore.Updated fires once per core state update (Core.StateStore.changed): bridge frames, or the
	core's fake generator when there is no robot (see Core.StateStore).
	StateStore.isFresh(maxAge) is true if a core update came within maxAge seconds (default 1) while a robot
	is connected (core status "live" or "mock"); never for the core's fake generator, so with no robot the
	arcade's arm holds still.
	StateStore.update(msg) is kept for old callers and does nothing: only the core writes robot state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("StateStore"))
local Grid = require(ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Grid"))

local StateStore = {}

StateStore.Updated = Instance.new("BindableEvent")

local lastUpdate = -math.huge -- os.clock() of the last core update
local source = nil            -- the core state `state` was converted from
local state = { arm = nil, tip = nil, blocks = {}, tower = 0 }

local function cm(mm)
	local n = tonumber(mm)
	return n and n / 10 or nil
end

local function tipOf(arm)
	local tip = type(arm.tip) == "table" and arm.tip or nil
	if not tip then
		local points = arm.points
		for _, p in ipairs(points) do
			if p.name == "tip" then
				tip = p
			end
		end
		tip = tip or points[#points]
	end
	if not (tip and tonumber(tip.x) and tonumber(tip.y)) then
		return nil
	end
	return { x = cm(tip.x), y = cm(tip.y), z = cm(tip.z) or 0 }
end

-- A Core.StateStore state -> the arcade shape above.
function StateStore.convert(core)
	local out = { arm = nil, tip = nil, blocks = {}, tower = 0 }
	if type(core) ~= "table" then
		return out
	end
	out.seq, out.ts = core.seq, core.ts
	local arm = core.arm
	if type(arm) == "table" then
		if type(arm.joints) == "table" and next(arm.joints) ~= nil then
			out.arm = table.clone(arm.joints)
		end
		if type(arm.points) == "table" then
			out.tip = tipOf(arm)
		end
	end
	for _, b in ipairs(core.blocks or {}) do
		if type(b) == "table" then
			local block = table.clone(b)
			local okCell, cell = false, nil
			if tonumber(b.x) and tonumber(b.y) then
				okCell, cell = pcall(Grid.cellOfBlock, b)
			end
			block.cell = okCell and cell or nil
			block.x_mm, block.y_mm, block.z_mm = b.x, b.y, b.z
			block.x, block.y, block.z = cm(b.x), cm(b.y), cm(b.z)
			table.insert(out.blocks, block)
		end
	end
	return out
end

function StateStore.get()
	local core = Core.get()
	if core ~= source then
		source = core
		state = StateStore.convert(core)
	end
	return state
end

-- True if a core state update came within maxAge seconds (default 1) and a robot is connected.
function StateStore.isFresh(maxAge)
	local status = Core.status()
	return (status == "live" or status == "mock") and os.clock() - lastUpdate < (maxAge or 1)
end

-- Old API: Shared.Bridge used to push decoded messages here. The core owns robot state now.
function StateStore.update(_msg) end

Core.changed:Connect(function()
	lastUpdate = os.clock()
	StateStore.Updated:Fire()
end)

return StateStore
