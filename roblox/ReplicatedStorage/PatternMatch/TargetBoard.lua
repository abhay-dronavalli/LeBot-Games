-- ReplicatedStorage.PatternMatch.TargetBoard
-- Draws a target on a board as 3D blocks (PatternMatch.BlockPool, identical to the LiveBoard's): one
-- block per tower level in its color on each target cell, nothing on the others. Tiles stay the neutral
-- tile color. Hard mode outlines the target blocks, and in its hidden phase turns every level gray, so
-- the player still sees which cells need a block and how tall, but not the colors. Outlines are one
-- SelectionBox per block part, made once and shown or hidden.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local BlockPool = require(script.Parent.BlockPool)

local NEUTRAL = Color3.fromHex("f7f6f2")      -- tile color: the paper sheet
local HIDDEN = Color3.fromRGB(176, 176, 176)  -- Hard mode's hidden phase: clearly gray on the paper, light
                                              -- enough to read as gray rather than black
local OUTLINE = Color3.fromRGB(15, 15, 15)

local TargetBoard = {}
TargetBoard.__index = TargetBoard
TargetBoard.NEUTRAL = NEUTRAL
TargetBoard.HIDDEN = HIDDEN

function TargetBoard.new(boardModel)
	local self = setmetatable({ board = boardModel, cells = Grid.allCells(), outlines = {} }, TargetBoard)
	self.blocks = BlockPool.new(boardModel)
	for _, cell in ipairs(self.cells) do
		local tile = boardModel[cell]
		if tile.Color ~= NEUTRAL then
			tile.Color = NEUTRAL
		end
		self.outlines[cell] = {}
		for level = 0, self.blocks.levels - 1 do
			local block = self.blocks:part(cell, level)
			local outline = block:FindFirstChild("TargetOutline")
			if not outline then
				outline = Instance.new("SelectionBox")
				outline.Name = "TargetOutline"
				outline.Adornee = block
				outline.Color3 = OUTLINE
				outline.LineThickness = 0.08
				outline.Visible = false
				outline.Parent = block
			end
			self.outlines[cell][level] = outline
		end
	end
	return self
end

-- target: cell -> tower (list of color names bottom to top), or nil to clear the board.
-- hidden: target blocks turn gray instead of their color. outlined: target blocks get an outline.
function TargetBoard:show(target, hidden, outlined)
	for _, cell in ipairs(self.cells) do
		local tower = target and target[cell]
		for level = 0, self.blocks.levels - 1 do
			local colorName = tower and tower[level + 1]
			local color = nil
			if colorName then
				color = hidden and HIDDEN or Config.colors[colorName] or HIDDEN
			end
			self.blocks:set(cell, level, color)
			local outline = self.outlines[cell][level]
			local visible = colorName ~= nil and outlined == true
			if outline.Visible ~= visible then
				outline.Visible = visible
			end
		end
	end
end

return TargetBoard
