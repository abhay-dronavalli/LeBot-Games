-- DebugMode (Section 10.1) -- fake Bridge data source + cell editor backend.
-- Active only when Config.DebugMode = true. Emits the same `cells` structure Section 12.1 defines,
-- so later steps (BlockSync, SkyArm) can't tell the difference between this and the real robot feed.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

if not Config.DebugMode then
	return
end

-- Exactly one source may own the crates, but WHICH one is a runtime choice now, not a startup
-- constant: the debug menu flips it mid-session. So this script always loads and simply stays
-- quiet unless it is the current source. An earlier version returned here whenever
-- Config.LiveFeed was set, which also took the debug menu out with it.
local RunControl = require(ServerScriptService:WaitForChild("RunControl"))

local function isSource()
	return RunControl.feedMode == "sim"
end

local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))
local SkyArm = require(ServerScriptService:WaitForChild("SkyArm"))
-- Follows whichever bay is live (RunControl), so jumping to a scenario in the debug menu
-- points the cell editor at THAT bay. It used to pin Bay01, which meant every scenario after
-- the first looked unsolvable: the clicks went to a bay nobody was standing in.
local function targetBayModel()
	return RunControl.activeBayModel()
		or Workspace:WaitForChild("Warehouse"):WaitForChild("Bay01")
end

SkyArm.setActiveBay(targetBayModel())

-- (the reset handler is registered further down, once cellState exists -- a closure only
-- sees locals declared above it, and reading one declared below silently gets a nil global.)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CellEdit = Remotes:WaitForChild("CellEdit")
local CellsUpdated = Remotes:WaitForChild("CellsUpdated")
local DebugHotkey = Remotes:WaitForChild("DebugHotkey")

local COLOR_CYCLE = {"none", "red", "blue", "yellow", "green", "orange", "purple", "teal"}

-- cellState[col][row] = {color=, level=} or nil
local cellState = {}
local previousCellsList = {}

local function buildCellsList()
	local list = {}
	for col = 0, Config.BayCols - 1 do
		for row = 0, Config.BayRows - 1 do
			local cell = cellState[col] and cellState[col][row]
			if cell then
				table.insert(list, {
					col = col,
					row = row,
					color = cell.color,
					level = cell.level,
					ids = (cell.level == 2) and {0, 0} or {0}, -- fake ArUco ids in Debug Mode
				})
			end
		end
	end
	table.sort(list, function(a, b)
		if a.col == b.col then
			return a.row < b.row
		end
		return a.col < b.col
	end)
	return list
end

local function keyFor(c)
	return c.col .. "," .. c.row
end

local function diffCells(oldList, newList)
	local oldByKey, newByKey = {}, {}
	for _, c in ipairs(oldList) do
		oldByKey[keyFor(c)] = c
	end
	for _, c in ipairs(newList) do
		newByKey[keyFor(c)] = c
	end

	local added, removed, changed = {}, {}, {}
	for key, c in pairs(newByKey) do
		local old = oldByKey[key]
		if not old then
			table.insert(added, c)
		elseif old.color ~= c.color or old.level ~= c.level then
			table.insert(changed, c)
		end
	end
	for key, c in pairs(oldByKey) do
		if not newByKey[key] then
			table.insert(removed, c)
		end
	end
	return added, removed, changed
end

RunControl.ActiveBayChanged:Connect(function()
	cellState = {}
	previousCellsList = {}
	SkyArm.setActiveBay(targetBayModel())
end)

local function applyAndBroadcast()
	local newList = buildCellsList()
	local added, removed, changed = diffCells(previousCellsList, newList)
	if #added > 0 or #removed > 0 or #changed > 0 then
		print(string.format("[DebugMode] cells diff: +%d -%d ~%d", #added, #removed, #changed))
		for _, c in ipairs(added) do
			print(string.format("  + (%d,%d) %s L%d", c.col, c.row, c.color, c.level))
		end
		for _, c in ipairs(changed) do
			print(string.format("  ~ (%d,%d) %s L%d", c.col, c.row, c.color, c.level))
		end
		for _, c in ipairs(removed) do
			print(string.format("  - (%d,%d) %s L%d", c.col, c.row, c.color, c.level))
		end
	end
	previousCellsList = newList
	CellsUpdated:FireAllClients(newList)
	BlockSync.applyCells(targetBayModel(), newList)
	return newList
end

CellEdit.OnServerEvent:Connect(function(player, col, row, action)
	if not isSource() then
		return
	end
	if type(col) ~= "number" or type(row) ~= "number" then
		return
	end
	if col < 0 or col >= Config.BayCols or row < 0 or row >= Config.BayRows then
		return
	end

	cellState[col] = cellState[col] or {}
	local cell = cellState[col][row]

	if action == "toggleLevel" then
		if cell then
			cell.level = (cell.level == 1) and 2 or 1
		end
	else -- "cycle"
		local currentIndex = 1
		if cell then
			for i, name in ipairs(COLOR_CYCLE) do
				if name == cell.color then
					currentIndex = i
					break
				end
			end
		end
		local nextIndex = (currentIndex % #COLOR_CYCLE) + 1
		local nextColor = COLOR_CYCLE[nextIndex]
		if nextColor == "none" then
			cellState[col][row] = nil
		else
			cellState[col][row] = {color = nextColor, level = (cell and cell.level) or 1}
		end
	end

	applyAndBroadcast()
end)

----------------------------------------------------------------
-- Hotkeys (Section 10.1) -- most are stubs until their owning systems (GameState,
-- ActiveBayTracker, Events, SkyArm) exist; they print so the mapping can be verified now.
----------------------------------------------------------------
local craneActive = false

DebugHotkey.OnServerEvent:Connect(function(player, key)
	if key == "R" then
		cellState = {}
		applyAndBroadcast()
		print("[DebugMode] R: reset run (cells cleared; GameState reset not wired yet)")
	elseif key == "H" then
		craneActive = not craneActive
		print("[DebugMode] H: held Purple crane ->", craneActive)
	elseif key == "T" then
		print("[DebugMode] T: +10s (GameState clock not wired yet)")
	elseif key == "K" then
		print("[DebugMode] K: kill active malfunction (Events not wired yet)")
	elseif key == "M" then
		print("[DebugMode] M: trigger malfunction (Events not wired yet)")
	elseif key == "N" then
		print("[DebugMode] N: next bay (ActiveBayTracker not wired yet)")
	elseif tonumber(key) then
		local bayIndex = tonumber(key)
		local bayModel = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", bayIndex))
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if bayModel and hrp then
			local zStart = (bayIndex - 1) * Config.BayPitch
			hrp.CFrame = CFrame.new(Config.BayWidth / 2, 4, zStart + 2)
			SkyArm.setActiveBay(bayModel)
			print("[DebugMode] " .. key .. ": teleported to Bay " .. bayIndex .. " (quick-travel, not the real ActiveBayTracker)")
		end
	end
end)

----------------------------------------------------------------
-- Mock arm (Section 10.1) -- drives the six joints with a gentle sine wave, so later
-- steps (Sky Arm) have a fake feed to render without the real robot.
----------------------------------------------------------------
local armState = {
	shoulder_pan = 0, shoulder_lift = 0, elbow_flex = 0,
	wrist_flex = 0, wrist_roll = 0, gripper = 0,
}

task.spawn(function()
	while Config.DebugMode do
		local t = os.clock()
		armState.shoulder_pan = math.sin(t * 0.3) * 30
		armState.shoulder_lift = math.sin(t * 0.25 + 1) * 20 - 20
		armState.elbow_flex = math.sin(t * 0.4 + 2) * 25 + 40
		armState.wrist_flex = math.sin(t * 0.5 + 3) * 15
		armState.wrist_roll = math.sin(t * 0.2) * 10
		armState.gripper = (math.sin(t * 0.6) + 1) * 25
		task.wait(1 / 20) -- ~20 Hz, matching the planned WebSocket rate
	end
end)

print("[DebugMode] fake Bridge source + cell editor backend online")
