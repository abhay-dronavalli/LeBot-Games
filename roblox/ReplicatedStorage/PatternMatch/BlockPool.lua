-- ReplicatedStorage.PatternMatch.BlockPool
-- One block Part per cell of a board, made once and then shown, hidden or recolored through its
-- properties, so nothing is created per tick. LiveBoard and TargetBoard both use it, so their blocks
-- look identical: a cube 60% of the tile's width, sitting on the tile, in a Blocks folder in the board.
-- The parts belong to the board Model, so they turn with spins and shake with tremors.

local Grid = require(script.Parent.Grid)

local BLOCK_FRACTION = 0.6 -- block width as a fraction of its cell tile

local BlockPool = {}
BlockPool.__index = BlockPool

function BlockPool.new(boardModel)
	local self = setmetatable({ parts = {} }, BlockPool)
	local folder = boardModel:FindFirstChild("Blocks")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Blocks"
		folder.Parent = boardModel
	end
	for _, cell in ipairs(Grid.allCells()) do
		local tile = boardModel:FindFirstChild(cell)
		assert(tile and tile:IsA("BasePart"), "BlockPool: board has no cell part " .. cell)
		local part = folder:FindFirstChild(cell)
		if not part then
			local width = math.min(tile.Size.X, tile.Size.Z) * BLOCK_FRACTION
			part = Instance.new("Part")
			part.Name = cell
			part.Size = Vector3.new(width, width, width)
			part.CFrame = tile.CFrame * CFrame.new(0, (tile.Size.Y + width) / 2, 0)
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Material = Enum.Material.SmoothPlastic
			part.Transparency = 1
			part.Parent = folder
		end
		self.parts[cell] = part
	end
	return self
end

-- Shows the cell's block in `color` (a Color3), or hides it when color is nil.
function BlockPool:set(cell, color)
	local part = self.parts[cell]
	if color then
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

return BlockPool
