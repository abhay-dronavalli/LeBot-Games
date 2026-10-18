-- ReplicatedStorage.PatternMatch.TargetBoard
-- Draws a target on a board as 3D blocks (PatternMatch.BlockPool, identical to the LiveBoard's): one
-- block in its color on each target cell, nothing on the others. Tiles stay the neutral tile color.
-- Hard mode outlines the target blocks, and in its hidden phase turns them gray, so the player still
-- sees which cells need a block but not the color. Outlines are one SelectionBox per block, made once
-- and shown or hidden.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)
local BlockPool = require(script.Parent.BlockPool)

local NEUTRAL = Color3.fromRGB(200, 200, 200) -- tile color
local HIDDEN = Color3.fromRGB(180, 180, 180)  -- Hard mode's hidden phase: just under the tile gray, so the
                                              -- shaded block still reads as gray against its outline
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
		local block = self.blocks.parts[cell]
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
		self.outlines[cell] = outline
	end
	return self
end

-- target: cell -> color name, or nil to clear the board.
-- hidden: target blocks turn gray instead of their color. outlined: target blocks get an outline.
function TargetBoard:show(target, hidden, outlined)
	for _, cell in ipairs(self.cells) do
		local colorName = target and target[cell]
		local color = nil
		if colorName then
			color = hidden and HIDDEN or Config.colors[colorName] or HIDDEN
		end
		self.blocks:set(cell, color)
		local outline = self.outlines[cell]
		local visible = colorName ~= nil and outlined == true
		if outline.Visible ~= visible then
			outline.Visible = visible
		end
	end
end

return TargetBoard
