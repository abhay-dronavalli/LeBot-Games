-- ReplicatedStorage.PatternMatch.Grid
-- Table cm -> grid cell, and grid cell -> world position on a board model.
--
-- Matches the printed grid sheet: 3 rows x 4 columns, cells "A1".."C4" (letter = row, number = column).
-- Table frame (plan.md): cm, x from tag 0 toward tag 1 (along the columns), y from tag 0 toward tag 3
-- (along the rows), z up. Row A is on the arm side (nearest tags 0 and 1), row C toward the tripod.
-- Column 1 is nearest tag 0, column 4 nearest tag 1.

local Config = require(script.Parent.Config)

local ROW_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

local Grid = {}

-- (row, col) -> "B3"
function Grid.cellName(row, col)
	return string.sub(ROW_LETTERS, row, row) .. tostring(col)
end

-- "B3" -> 2, 3 (row, col). Returns nil for anything that isn't a cell on this grid.
function Grid.parseCell(cell)
	if type(cell) ~= "string" then
		return nil
	end
	local letter, digits = string.match(cell, "^(%u)(%d+)$")
	if not letter then
		return nil
	end
	local row = string.find(ROW_LETTERS, letter, 1, true)
	local col = tonumber(digits)
	if row > Config.gridRows or col < 1 or col > Config.gridCols then
		return nil
	end
	return row, col
end

-- Every cell, row by row: A1, A2, A3, A4, B1, ...
function Grid.allCells()
	local cells = {}
	for row = 1, Config.gridRows do
		for col = 1, Config.gridCols do
			table.insert(cells, Grid.cellName(row, col))
		end
	end
	return cells
end

-- Table position in cm -> "A1".."C4", or nil if off grid.
-- A position only counts if it sits inside the middle cellTolerance (70%) of its cell.
-- Config.flipX mirrors columns (1 <-> 4) and Config.flipY mirrors rows (A <-> C).
function Grid.cellOf(xCm, yCm)
	local u = (xCm - Config.gridOriginCm.X) / Config.cellSizeCm
	local v = (yCm - Config.gridOriginCm.Y) / Config.cellSizeCm
	local col = math.floor(u) + 1
	local row = math.floor(v) + 1
	if col < 1 or col > Config.gridCols or row < 1 or row > Config.gridRows then
		return nil
	end

	local margin = (1 - Config.cellTolerance) / 2
	local fu = u - (col - 1)
	local fv = v - (row - 1)
	if fu < margin or fu > 1 - margin or fv < margin or fv > 1 - margin then
		return nil
	end
	if Config.flipX then
		col = Config.gridCols + 1 - col
	end
	if Config.flipY then
		row = Config.gridRows + 1 - row
	end
	return Grid.cellName(row, col)
end

-- StateStore block -> the cell its x,y sits in, or nil if it doesn't count: held, in an ignored zone
-- such as the tray, or off grid. Stacked blocks (level > 0) get a cell too; liveGridFrom keeps the
-- levels apart. visible == false still counts: the core keeps tracking a block at its last pose while
-- its marker is hidden (under a stack, under the arm).
function Grid.cellOfBlock(block)
	if block.held == true or Config.ignoreZones[block.zone] then
		return nil
	end
	return Grid.cellOf(block.x, block.y)
end

-- A block's stack level as a whole number >= 0 (0 = on the table). The core owns stack logic, so the
-- reported level is taken as is: a level 1 block with nothing under it still sits at level 1.
function Grid.levelOf(block)
	return math.max(0, math.floor(tonumber(block.level) or 0))
end

-- StateStore blocks -> live grid: { [cell] = { [level] = { color, ... } } } for every cell holding at
-- least one counted block. Each cell is a table indexed by level (0 = table, 1 = on top of a level 0
-- block, ...) holding the colors of the blocks reported at that level: 2+ colors means a doubled level.
-- Levels at or above Config.maxStackGlobal are kept too, so Target.compare can report them as extra.
function Grid.liveGridFrom(blocks)
	local liveGrid = {}
	for _, block in ipairs(blocks) do
		local cell = Grid.cellOfBlock(block)
		if cell then
			local entry = liveGrid[cell]
			if not entry then
				entry = {}
				liveGrid[cell] = entry
			end
			local level = Grid.levelOf(block)
			local colors = entry[level]
			if not colors then
				colors = {}
				entry[level] = colors
			end
			table.insert(colors, block.color)
		end
	end
	return liveGrid
end

-- The levels present in a live grid cell entry, lowest first. {} for nil.
function Grid.levelsOf(entry)
	local levels = {}
	for level in pairs(entry or {}) do
		table.insert(levels, level)
	end
	table.sort(levels)
	return levels
end

-- Cell -> world position at the center of that cell on top of the board's Base part.
-- boardModel is a board Model with a Base part, or the Base part itself.
-- Rows A-C run along the Base's local -Z (row A, the arm side, at the +Z edge). Columns 1-4 run along
-- its local -X (column 1, the tag 0 side, at the +X edge). That matches the printed sheet: standing at
-- the row C (tripod) side looking toward row A, A1 is far-left and the columns read 1 2 3 4 left to
-- right; standing at the arm side looking toward the tripod, tag 0 / A1 is on the right. Rendering only:
-- Grid.cellOf (table cm -> cell) is unaffected. The result follows the board when it is moved or spun.
function Grid.worldPositionOf(cell, boardModel)
	local row, col = Grid.parseCell(cell)
	if not row then
		return nil
	end
	local base = boardModel
	if not base:IsA("BasePart") then
		base = boardModel:FindFirstChild("Base")
	end
	assert(base and base:IsA("BasePart"), "Grid.worldPositionOf: board needs a Base part")

	local size = base.Size
	local localX = (0.5 - (col - 0.5) / Config.gridCols) * size.X
	local localZ = (0.5 - (row - 0.5) / Config.gridRows) * size.Z
	return base.CFrame:PointToWorldSpace(Vector3.new(localX, size.Y / 2, localZ))
end

return Grid
