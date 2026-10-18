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

