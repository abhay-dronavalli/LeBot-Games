-- ReplicatedStorage.PatternMatch.Grid
-- Table cm -> grid cell, and grid cell -> world position on a board model.
--
-- Cell names are column letter + row number: "A1".."D3".
-- Columns A-D run left to right as the operator sees them from the follower arm (+x in table cm).
-- Rows 1-3 run from the arm toward the tripod (+y in table cm). Row 1 is nearest the arm.

local Config = require(script.Parent.Config)

local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

local Grid = {}

function Grid.cellName(col, row)
	return string.sub(LETTERS, col, col) .. tostring(row)
end

-- "B3" -> 2, 3. Returns nil for anything that isn't a cell on this grid.
function Grid.parseCell(cell)
	if type(cell) ~= "string" then
		return nil
	end
	local letter, digits = string.match(cell, "^(%u)(%d+)$")
	if not letter then
		return nil
	end
	local col = string.find(LETTERS, letter, 1, true)
	local row = tonumber(digits)
	if col > Config.gridCols or row < 1 or row > Config.gridRows then
		return nil
	end
	return col, row
end

-- Every cell, column-major: A1, A2, A3, B1, ...
function Grid.allCells()
	local cells = {}
	for col = 1, Config.gridCols do
		for row = 1, Config.gridRows do
			table.insert(cells, Grid.cellName(col, row))
		end
	end
	return cells
end

-- Table position in cm -> "A1".."D3", or nil if off grid.
-- A position only counts if it sits inside the middle cellTolerance (70%) of its cell.
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
	return Grid.cellName(col, row)
end

-- StateStore block -> cell, or nil if it doesn't count (held, stacked, not visible, off grid).
function Grid.cellOfBlock(block)
	if block.held == true or block.visible == false or block.level ~= 0 then
		return nil
	end
	return Grid.cellOf(block.x, block.y)
end

-- Cell -> world position at the center of that cell on top of the board's Base part.
-- boardModel is a board Model with a Base part, or the Base part itself.
-- Columns run along the Base's local +X, rows along its local -Z (row 1 at the +Z edge),
-- so the result follows the board when it is moved or spun.
function Grid.worldPositionOf(cell, boardModel)
	local col, row = Grid.parseCell(cell)
	if not col then
		return nil
	end
	local base = boardModel
	if not base:IsA("BasePart") then
		base = boardModel:FindFirstChild("Base")
	end
	assert(base and base:IsA("BasePart"), "Grid.worldPositionOf: board needs a Base part")

	local size = base.Size
	local localX = ((col - 0.5) / Config.gridCols - 0.5) * size.X
	local localZ = (0.5 - (row - 0.5) / Config.gridRows) * size.Z
	return base.CFrame:PointToWorldSpace(Vector3.new(localX, size.Y / 2, localZ))
end

return Grid
