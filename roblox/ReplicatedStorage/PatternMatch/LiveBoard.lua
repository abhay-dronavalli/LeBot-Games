-- ReplicatedStorage.PatternMatch.LiveBoard
-- Draws the real table on a board: one colored block (PatternMatch.BlockPool) per cell and stack level
-- with a block on the table. The board Model needs cell Parts named A1..C4.
-- A block whose color isn't in Config.colors (a perception misread) is drawn gray.
-- A doubled level (2+ blocks reported at one cell and level) shows one block; blocks at levels the pool
-- doesn't have (>= Config.maxStackGlobal) aren't drawn. Target.compare still reports both, and
-- showProblems puts a thick white outline (one SelectionBox per block part, made once) on the specific
-- block behind each problem. White is not a block color, so the outline shows against every block.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local BlockPool = require(script.Parent.BlockPool)

local MISREAD_COLOR = Color3.fromRGB(150, 150, 150) -- a misread: a color name Config.colors doesn't have
local PROBLEM_OUTLINE = Color3.new(1, 1, 1)

local LiveBoard = {}
LiveBoard.__index = LiveBoard

function LiveBoard.new(boardModel)
	local self = setmetatable({ board = boardModel, highlights = {}, tiles = {} }, LiveBoard)
	self.blocks = BlockPool.new(boardModel)

	for _, cell in ipairs(Grid.allCells()) do
		self.tiles[cell] = boardModel[cell]
		self.highlights[cell] = {}
		for level = 0, self.blocks.levels - 1 do
			local block = self.blocks:part(cell, level)
			local highlight = block:FindFirstChild("ProblemHighlight")
			if not highlight then
				highlight = Instance.new("SelectionBox")
				highlight.Name = "ProblemHighlight"
				highlight.Adornee = block
				highlight.Color3 = PROBLEM_OUTLINE
				highlight.LineThickness = 0.15
				highlight.SurfaceTransparency = 1
				highlight.Visible = false
				highlight.Parent = block
			end
			self.highlights[cell][level] = highlight
		end
	end
	return self
end

-- White outline on each listed block: problemLevels is Target.compare's { [cell] = { [level] = true } }
-- (extra, doubled and misread blocks). A level above the pool's top is shown on the top block, since
-- that is where the offending block sits. nil or {} clears all.
function LiveBoard:showProblems(problemLevels)
	local top = self.blocks.levels - 1
	for cell, highlights in pairs(self.highlights) do
		local wanted = {}
		for level in pairs(problemLevels and problemLevels[cell] or {}) do
			wanted[math.min(level, top)] = true
		end
		for level, highlight in pairs(highlights) do
			local visible = wanted[level] == true
			if highlight.Visible ~= visible then
				highlight.Visible = visible
			end
		end
	end
end

-- Shows the given StateStore blocks and returns the live grid (Grid.liveGridFrom) it drew.
function LiveBoard:render(blocks)
	local liveGrid = Grid.liveGridFrom(blocks)
	for cell in pairs(self.tiles) do
		local entry = liveGrid[cell]
		for level = 0, self.blocks.levels - 1 do
			local colorName = entry and entry[level] and entry[level][1]
			self.blocks:set(cell, level, colorName and (Config.colors[colorName] or MISREAD_COLOR) or nil)
		end
	end
	return liveGrid
end

return LiveBoard
