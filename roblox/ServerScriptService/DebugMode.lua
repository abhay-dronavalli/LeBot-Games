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
-- Hardcoded to Bay 1 until ActiveBayTracker (Section 10.2 step 6) exists to pick the real active bay.
local targetBay = Workspace:WaitForChild("Warehouse"):WaitForChild("Bay01")
SkyArm.setActiveBay(targetBay)

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
	BlockSync.applyCells(targetBay, newList)
	return newList
end

CellEdit.OnServerEvent:Connect(function(player, col, row, action)
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
