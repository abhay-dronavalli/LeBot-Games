-- ReplicatedStorage.PatternMatch.BlockPool
-- One block Part per cell and stack level of a board (12 cells x Config.maxStackGlobal levels), made
-- once and then shown, hidden or recolored through its properties, so nothing is created per tick.
-- LiveBoard and TargetBoard both use it, so their blocks look identical: a cube 60% of the tile's
-- width, sitting on the tile at level 0 and one cube higher per level, in a Blocks folder in the board.
-- The parts belong to the board Model, so they turn with spins and shake with tremors.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local BLOCK_FRACTION = 0.6 -- block width as a fraction of its cell tile

local BlockPool = {}
BlockPool.__index = BlockPool

-- Part name for a cell's block at a level: "B2" on the table, "B2_1" on top of it, ...
function BlockPool.partName(cell, level)
	return level == 0 and cell or cell .. "_" .. level
end

function BlockPool.new(boardModel)
	local self = setmetatable({ parts = {}, levels = Config.maxStackGlobal }, BlockPool)
	local folder = boardModel:FindFirstChild("Blocks")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Blocks"
		folder.Parent = boardModel
	end
	for _, cell in ipairs(Grid.allCells()) do
		local tile = boardModel:FindFirstChild(cell)
		assert(tile and tile:IsA("BasePart"), "BlockPool: board has no cell part " .. cell)
		local width = math.min(tile.Size.X, tile.Size.Z) * BLOCK_FRACTION
		self.parts[cell] = {}
		for level = 0, self.levels - 1 do
			local name = BlockPool.partName(cell, level)
			local part = folder:FindFirstChild(name)
			if not part then
				part = Instance.new("Part")
				part.Name = name
				part.Size = Vector3.new(width, width, width)
				part.CFrame = tile.CFrame * CFrame.new(0, (tile.Size.Y + width) / 2 + level * width, 0)
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.Material = Enum.Material.SmoothPlastic
				part.Transparency = 1
				part.Parent = folder
			end
			self.parts[cell][level] = part
		end
	end
	return self
end

-- The part for a cell's block at a level, or nil above the pool's top level.
function BlockPool:part(cell, level)
	local tower = self.parts[cell]
	return tower and tower[level] or nil
end

-- Shows the cell's block at `level` in `color` (a Color3), or hides it when color is nil.
function BlockPool:set(cell, level, color)
	local part = self.parts[cell][level]
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

-- Shows a whole tower: colors is a list of Color3 (or nil) bottom to top; levels past it are hidden.
function BlockPool:setTower(cell, colors)
	for level = 0, self.levels - 1 do
		self:set(cell, level, colors and colors[level + 1] or nil)
	end
end

return BlockPool
