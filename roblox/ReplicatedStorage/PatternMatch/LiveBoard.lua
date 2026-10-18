-- ReplicatedStorage.PatternMatch.LiveBoard
-- Draws the real table on a board: one colored block (PatternMatch.BlockPool) on each cell with a
-- block on the table. The board Model needs cell Parts named A1..C4.
-- Stacked or doubled blocks don't get parts of their own yet; Target.compare still reports them, and
-- showProblems puts a thick white outline (one SelectionBox per tile, made once) on those cells.
-- White is not a block color, so the outline shows against every block.
-- setVanished makes tiles fully transparent for the Vanishing Tile event.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local BlockPool = require(script.Parent.BlockPool)

local UNKNOWN_COLOR = Color3.fromRGB(255, 255, 255) -- a color name missing from Config.colors
local PROBLEM_OUTLINE = Color3.new(1, 1, 1)

local LiveBoard = {}
LiveBoard.__index = LiveBoard

function LiveBoard.new(boardModel)
	local self = setmetatable({ board = boardModel, highlights = {}, tiles = {} }, LiveBoard)
	self.blocks = BlockPool.new(boardModel)

	for _, cell in ipairs(Grid.allCells()) do
		local tile = boardModel[cell]
		local highlight = tile:FindFirstChild("ProblemHighlight")
		if not highlight then
			highlight = Instance.new("SelectionBox")
			highlight.Name = "ProblemHighlight"
			highlight.Adornee = tile
			highlight.Color3 = PROBLEM_OUTLINE
			highlight.LineThickness = 0.2
			highlight.SurfaceTransparency = 1
			highlight.Visible = false
			highlight.Parent = tile
		end
		self.highlights[cell] = highlight
		self.tiles[cell] = tile
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
	for cell in pairs(self.tiles) do
		local entry = liveGrid[cell]
		local colorName = entry and entry.colors[1]
		self.blocks:set(cell, colorName and (Config.colors[colorName] or UNKNOWN_COLOR) or nil)
	end
	return liveGrid
end

return LiveBoard
