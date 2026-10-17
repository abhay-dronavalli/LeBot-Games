-- ReplicatedStorage.PatternMatch.LiveBoard
-- Draws the real table on a board: one colored block Part on each occupied cell.
-- The board Model needs cell Parts named A1..D3 and a Blocks folder (made here if missing).
-- Block parts are pooled, one per cell, created once and shown or hidden with Transparency.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local BLOCK_FRACTION = 0.6                        -- block width as a fraction of its cell part
local UNKNOWN_COLOR = Color3.fromRGB(255, 255, 255) -- a color name missing from Config.colors

local LiveBoard = {}
LiveBoard.__index = LiveBoard

-- StateStore blocks -> { [cell] = colorName }, counting only blocks Grid.cellOfBlock accepts.
-- If two counted blocks land in one cell, the later one wins.
function LiveBoard.liveGridFrom(blocks)
	local liveGrid = {}
	for _, block in ipairs(blocks) do
		local cell = Grid.cellOfBlock(block)
		if cell then
			liveGrid[cell] = block.color
		end
	end
	return liveGrid
end

function LiveBoard.new(boardModel)
	local self = setmetatable({ board = boardModel, pool = {} }, LiveBoard)

	local folder = boardModel:FindFirstChild("Blocks")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Blocks"
		folder.Parent = boardModel
	end

	for _, cell in ipairs(Grid.allCells()) do
		local cellPart = boardModel:FindFirstChild(cell)
		assert(cellPart and cellPart:IsA("BasePart"), "LiveBoard: board has no cell part " .. cell)
		local part = folder:FindFirstChild(cell)
		if not part then
			local width = math.min(cellPart.Size.X, cellPart.Size.Z) * BLOCK_FRACTION
			part = Instance.new("Part")
			part.Name = cell
			part.Size = Vector3.new(width, width, width)
			part.CFrame = cellPart.CFrame * CFrame.new(0, (cellPart.Size.Y + width) / 2, 0)
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Material = Enum.Material.SmoothPlastic
			part.Transparency = 1
			part.Parent = folder
		end
		self.pool[cell] = part
	end
	return self
end

-- Shows the given StateStore blocks and returns the live grid it drew.
function LiveBoard:render(blocks)
	local liveGrid = LiveBoard.liveGridFrom(blocks)
	for cell, part in pairs(self.pool) do
		local colorName = liveGrid[cell]
		if colorName then
			local color = Config.colors[colorName] or UNKNOWN_COLOR
			if part.Color ~= color then
				part.Color = color
			end
			if part.Transparency ~= 0 then
				part.Transparency = 0
			end
		elseif part.Transparency ~= 1 then
			part.Transparency = 1
		end
	end
	return liveGrid
end

return LiveBoard
