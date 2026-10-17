-- ReplicatedStorage.PatternMatch.LiveBoard
-- Draws the real table on a board: one colored block Part on each cell with a block on the table.
-- The board Model needs cell Parts named A1..C4 and a Blocks folder (made here if missing).
-- Block parts are pooled, one per cell, created once and shown or hidden with Transparency.
-- Stacked or doubled blocks don't get parts of their own yet; Target.compare still reports them, and
-- showProblems puts a thick white outline (one SelectionBox per tile, made once) on those cells.
-- White is not a block color, so the outline shows against every block.
-- setVanished makes tiles fully transparent for the Vanishing Tile event.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local BLOCK_FRACTION = 0.6                        -- block width as a fraction of its cell part
local UNKNOWN_COLOR = Color3.fromRGB(255, 255, 255) -- a color name missing from Config.colors
local PROBLEM_OUTLINE = Color3.new(1, 1, 1)

local LiveBoard = {}
LiveBoard.__index = LiveBoard

function LiveBoard.new(boardModel)
	local self = setmetatable({ board = boardModel, pool = {}, highlights = {}, tiles = {} }, LiveBoard)

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

		local highlight = cellPart:FindFirstChild("ProblemHighlight")
		if not highlight then
			highlight = Instance.new("SelectionBox")
			highlight.Name = "ProblemHighlight"
			highlight.Adornee = cellPart
			highlight.Color3 = PROBLEM_OUTLINE
			highlight.LineThickness = 0.2
			highlight.SurfaceTransparency = 1
			highlight.Visible = false
			highlight.Parent = cellPart
		end
		self.highlights[cell] = highlight
		self.tiles[cell] = cellPart
	end
	return self
end

-- Vanished tiles (a set of cells) turn fully transparent, label included; all others are restored.
function LiveBoard:setVanished(vanished)
	for cell, tile in pairs(self.tiles) do
		local gone = vanished ~= nil and vanished[cell] == true
		local transparency = gone and 1 or 0
		if tile.Transparency ~= transparency then
			tile.Transparency = transparency
			local label = tile:FindFirstChildOfClass("SurfaceGui")
			if label then
				label.Enabled = not gone
			end
		end
	end
end

-- White outline on each cell in the list (compare's extra, doubled and blocked cells); nil or {} clears all.
function LiveBoard:showProblems(cells)
	local wanted = {}
	for _, cell in ipairs(cells or {}) do
		wanted[cell] = true
	end
	for cell, highlight in pairs(self.highlights) do
		local visible = wanted[cell] == true
		if highlight.Visible ~= visible then
			highlight.Visible = visible
		end
	end
end

-- Shows the given StateStore blocks and returns the live grid (Grid.liveGridFrom) it drew.
function LiveBoard:render(blocks)
	local liveGrid = Grid.liveGridFrom(blocks)
	for cell, part in pairs(self.pool) do
		local entry = liveGrid[cell]
		local colorName = entry and entry.colors[1]
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
