-- ReplicatedStorage.PatternMatch.BlockPool
-- One block part per cell and stack level of a board (12 cells x Config.maxStackGlobal levels), made
-- once and then shown, hidden or recolored through its properties, so nothing is created per tick.
-- LiveBoard and TargetBoard both use it, so their blocks look identical: a matte foam cube 84% of a cell
-- wide (the real 48 mm block on the 57 mm cell), sitting on the tile at level 0 and one cube higher per
-- level, in a Blocks folder in the board. Each part is a clone of the rounded-cube MeshPart
-- ReplicatedStorage.PatternMatch.BlockMesh (stored by tools/build_pattern_cabinet.lua), or a plain Part
-- when that mesh is missing. The parts belong to the board Model, so they turn with spins and shake with
-- tremors.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local BLOCK_FRACTION = 0.84 -- block width as a fraction of the cell pitch (Config.boardCellStuds)

local BlockPool = {}
BlockPool.__index = BlockPool
BlockPool.BLOCK_FRACTION = BLOCK_FRACTION

local function newBlockPart()
	local template = script.Parent:FindFirstChild("BlockMesh")
	if template and template:IsA("MeshPart") then
		local part = template:Clone()
		part:ClearAllChildren()
		return part
	end
	return Instance.new("Part")
end

-- Where a block of `width` sits at `level` on `tile`: on the tile's top face, one block higher per level.
function BlockPool.restOn(tile, level, width)
	return tile.CFrame * CFrame.new(0, (tile.Size.Y + width) / 2 + level * width, 0)
end

-- Part name for a cell's block at a level: "B2" on the table, "B2_1" on top of it, ...
function BlockPool.partName(cell, level)
	return level == 0 and cell or cell .. "_" .. level
end

function BlockPool.new(boardModel)
	local width = Config.boardCellStuds * BLOCK_FRACTION
	local self = setmetatable({ parts = {}, tiles = {}, levels = Config.maxStackGlobal, width = width }, BlockPool)
	local folder = boardModel:FindFirstChild("Blocks")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Blocks"
		folder.Parent = boardModel
	end
	for _, cell in ipairs(Grid.allCells()) do
		local tile = boardModel:FindFirstChild(cell)
		assert(tile and tile:IsA("BasePart"), "BlockPool: board has no cell part " .. cell)
		self.tiles[cell] = tile
		self.parts[cell] = {}
		for level = 0, self.levels - 1 do
			local name = BlockPool.partName(cell, level)
			local part = folder:FindFirstChild(name)
			if not part then
				part = newBlockPart()
				part.Name = name
				part.Size = Vector3.new(width, width, width)
				part.CFrame = BlockPool.restOn(tile, level, width)
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

-- Animation helpers (the attract-mode demo). A block's pose is measured from its rest place on its tile,
-- read from the tile's current CFrame, so it stays right while the board spins or shakes.
-- lift: studs above the rest place; scale: size factor (the block stays centered on its rest place).
function BlockPool:pose(cell, level, lift, scale)
	local part = self.parts[cell][level]
	local size = self.width * (scale or 1)
	local wanted = Vector3.new(size, size, size)
	if part.Size ~= wanted then
		part.Size = wanted
	end
	part.CFrame = BlockPool.restOn(self.tiles[cell], level, self.width) * CFrame.new(0, lift or 0, 0)
end

-- Back to the rest place at full size.
function BlockPool:resetPose(cell, level)
	self:pose(cell, level, 0, 1)
end

-- Hides every block and puts each back at its rest place at full size.
function BlockPool:clear()
	for cell in pairs(self.parts) do
		for level = 0, self.levels - 1 do
			self:set(cell, level, nil)
			self:resetPose(cell, level)
		end
	end
end

return BlockPool
