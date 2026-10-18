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

local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))
local SkyArm = require(ServerScriptService:WaitForChild("SkyArm"))

-- Minimal stand-in for ActiveBayTracker (Section 10.2 step 6): the arm, the cell editor and
-- the crate deliveries all follow one active bay, and the quick-travel number keys move it.
-- This used to be hardcoded to Bay01, which meant every bay past the first was unreachable by
-- the real flow -- you could teleport into Bay 2 and edit cells, but the crates were delivered
-- into Bay 1 behind you.
--
-- Each bay keeps its OWN cell state. Sharing one table would make BlockSync, which diffs per
-- bay model, see every cell vanish from the bay you just left and have the arm dutifully
-- unload it.
local warehouse = Workspace:WaitForChild("Warehouse")
local activeBayIndex = 1
local targetBay = warehouse:WaitForChild("Bay01")
SkyArm.setActiveBay(targetBay)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CellEdit = Remotes:WaitForChild("CellEdit")
local CellsUpdated = Remotes:WaitForChild("CellsUpdated")
local DebugHotkey = Remotes:WaitForChild("DebugHotkey")

local COLOR_CYCLE = {"none", "red", "blue", "yellow", "green", "orange", "purple", "teal"}

-- cellStateByBay[bayIndex][col][row] = {color=, level=} or nil
local cellStateByBay = {}
local previousByBay = {}

local function cellStateFor(bayIndex)
	local cs = cellStateByBay[bayIndex]
	if not cs then
		cs = {}
		cellStateByBay[bayIndex] = cs
	end
	return cs
end

local function buildCellsList()
	local cellState = cellStateFor(activeBayIndex)
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

local function applyAndBroadcast()
	local newList = buildCellsList()
	local added, removed, changed = diffCells(previousByBay[activeBayIndex] or {}, newList)
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
	previousByBay[activeBayIndex] = newList
	CellsUpdated:FireAllClients(newList)
	BlockSync.applyCells(targetBay, newList)
	return newList
end

-- Point the arm, the editor grid and future deliveries at a different bay. Declared after
-- buildCellsList because a closure only sees locals declared above it -- reading it from here
-- when it was declared below would silently resolve to a nil global.
local function setActiveBay(bayIndex)
	local bayModel = warehouse:FindFirstChild(string.format("Bay%02d", bayIndex))
	if not bayModel then
		return nil
	end
	activeBayIndex = bayIndex
	targetBay = bayModel
	SkyArm.setActiveBay(bayModel)
	-- re-broadcast so the editor grid shows what is actually in the bay in front of you
	CellsUpdated:FireAllClients(buildCellsList())
	return bayModel
end

CellEdit.OnServerEvent:Connect(function(player, col, row, action)
	if type(col) ~= "number" or type(row) ~= "number" then
		return
	end
	if col < 0 or col >= Config.BayCols or row < 0 or row >= Config.BayRows then
		return
	end

	local cellState = cellStateFor(activeBayIndex)
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
		cellStateByBay[activeBayIndex] = {}
		applyAndBroadcast()
		print("[DebugMode] R: reset run (cells cleared for the active bay; GameState reset not wired yet)")
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
		-- moves the arm and the editor without moving the player, for watching a bay fill
		local nextIndex = (activeBayIndex % Config.NumBays) + 1
		if setActiveBay(nextIndex) then
			print("[DebugMode] N: active bay -> " .. nextIndex)
		end
	elseif tonumber(key) then
		local bayIndex = tonumber(key)
		local bayModel = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", bayIndex))
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if bayModel and hrp then
			-- land on the approach catwalk, not inside the bay: bay 2 has no floor at row 0 and
			-- the old +2 spawned you into thin air over the void.
			local zStart = (bayIndex - 1) * Config.BayPitch
			hrp.CFrame = CFrame.new(Config.BayWidth / 2, 4, zStart - 3)
			setActiveBay(bayIndex)
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
