-- ReplicatedStorage.PatternMatch.TargetBoard
-- Draws a target on a board: target cells in their color, the rest neutral.
-- Hard mode outlines the target cells, and in its hidden phase turns them gray, so the player still
-- sees which cells need a block but not the color. Outlines are one SelectionBox per tile, made once
-- and shown or hidden.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local NEUTRAL = Color3.fromRGB(200, 200, 200)
local HIDDEN = Color3.fromRGB(125, 125, 125)
local OUTLINE = Color3.fromRGB(15, 15, 15)

local TargetBoard = {}
TargetBoard.__index = TargetBoard
TargetBoard.NEUTRAL = NEUTRAL
TargetBoard.HIDDEN = HIDDEN

function TargetBoard.new(boardModel)
	local self = setmetatable({ board = boardModel, tiles = {}, outlines = {} }, TargetBoard)
	for _, cell in ipairs(Grid.allCells()) do
		local tile = boardModel:FindFirstChild(cell)
		assert(tile and tile:IsA("BasePart"), "TargetBoard: board has no cell part " .. cell)
		local outline = tile:FindFirstChild("TargetOutline")
		if not outline then
			outline = Instance.new("SelectionBox")
			outline.Name = "TargetOutline"
			outline.Adornee = tile
			outline.Color3 = OUTLINE
			outline.LineThickness = 0.08
			outline.Visible = false
			outline.Parent = tile
		end
		self.tiles[cell] = tile
		self.outlines[cell] = outline
	end
	return self
end

-- target: cell -> color name, or nil to blank the board.
-- hidden: target cells turn gray instead of their color. outlined: target cells get an outline.
function TargetBoard:show(target, hidden, outlined)
	for cell, tile in pairs(self.tiles) do
		local colorName = target and target[cell]
		local color = NEUTRAL
		if colorName then
			color = hidden and HIDDEN or Config.colors[colorName] or NEUTRAL
		end
		if tile.Color ~= color then
			tile.Color = color
		end
		local outline = self.outlines[cell]
		local visible = colorName ~= nil and outlined == true
		if outline.Visible ~= visible then
			outline.Visible = visible
		end
	end
end

return TargetBoard
