-- DebugCellEditor (Section 10.1) -- on-screen 4x3 grid: click cycles color, shift-click toggles level.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

if not Config.DebugMode then
	return
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CellEdit = Remotes:WaitForChild("CellEdit")
local CellsUpdated = Remotes:WaitForChild("CellsUpdated")
local DebugHotkey = Remotes:WaitForChild("DebugHotkey")

local COLOR_SWATCH = {
	red = Color3.fromRGB(220, 60, 60),
	blue = Color3.fromRGB(70, 160, 230),
	yellow = Color3.fromRGB(230, 210, 60),
	green = Color3.fromRGB(80, 200, 100),
	orange = Color3.fromRGB(235, 140, 40),
	purple = Color3.fromRGB(160, 90, 210),
	teal = Color3.fromRGB(60, 200, 190),
}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DebugCellEditor"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- This grid IS the operator in solo mode, so it is only on screen when it is actually the
-- crate source. In live the real arm owns the cells, and a clickable grid that silently does
-- nothing is worse than no grid at all.
local DebugStatus = Remotes:WaitForChild("DebugStatus")
screenGui.Enabled = false
DebugStatus.OnClientEvent:Connect(function(status)
	screenGui.Enabled = (status.feedMode == "solo")
end)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 280, 0, 24)
title.Position = UDim2.new(0, 16, 0, 462)
title.BackgroundTransparency = 0.3
title.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 14
title.Text = "DEBUG CELLS -- click=cycle color, shift+click=level"
title.Parent = screenGui

-- the grid reads as a map of the bay ahead of you, so say which end is which
local farLabel = Instance.new("TextLabel")
farLabel.Size = UDim2.new(0, 260, 0, 16)
farLabel.Position = UDim2.new(0, 16, 0, 488)
farLabel.BackgroundTransparency = 1
farLabel.TextColor3 = Color3.fromRGB(150, 150, 165)
farLabel.Font = Enum.Font.SourceSansBold
farLabel.TextSize = 12
farLabel.Text = "^ FAR END OF BAY"
farLabel.Parent = screenGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 260, 0, 200)
frame.Position = UDim2.new(0, 16, 0, 506)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
frame.BackgroundTransparency = 0.2
frame.Parent = screenGui

local nearLabel = farLabel:Clone()
nearLabel.Position = UDim2.new(0, 16, 0, 708)
nearLabel.Text = "v ENTRANCE (where you came in)"
nearLabel.Parent = screenGui

local layout = Instance.new("UIGridLayout")
layout.CellSize = UDim2.new(0, 56, 0, 56)
layout.CellPadding = UDim2.new(0, 6, 0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingLeft = UDim.new(0, 10)
padding.Parent = frame

local buttons = {}
for row = 0, Config.BayRows - 1 do
	for col = 0, Config.BayCols - 1 do
		local btn = Instance.new("TextButton")
		btn.Name = string.format("Cell_%d_%d", col, row)
		-- Lay the grid out as a MAP OF WHAT THE PLAYER SEES, not in raw index order.
		-- Walking into a bay you face +Z, and a Roblox character facing +Z has its
		-- RightVector pointing at -X -- so low columns are on your right, not your left, and
		-- row 0 (the entrance) is behind you rather than ahead. Both axes therefore flip:
		-- far row on top, high column on the left. Printed index order put the grid in a
		-- mirror image of the bay.
		btn.LayoutOrder = (Config.BayRows - 1 - row) * Config.BayCols
			+ (Config.BayCols - 1 - col)
		btn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
		btn.Text = string.format("%d,%d", col, row)
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.Font = Enum.Font.SourceSansBold
		btn.TextSize = 14
		btn.Parent = frame

		btn.MouseButton1Click:Connect(function()
			local shiftHeld = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			CellEdit:FireServer(col, row, shiftHeld and "toggleLevel" or "cycle")
		end)

		buttons[col .. "," .. row] = btn
	end
end

CellsUpdated.OnClientEvent:Connect(function(cellsList)
	for key, btn in pairs(buttons) do
		btn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
		btn.Text = key
	end
	for _, cell in ipairs(cellsList) do
		local btn = buttons[cell.col .. "," .. cell.row]
		if btn then
			btn.BackgroundColor3 = COLOR_SWATCH[cell.color] or Color3.fromRGB(80, 80, 80)
			btn.Text = string.format("%d,%d L%d", cell.col, cell.row, cell.level)
		end
	end
end)

local HOTKEYS = {
	[Enum.KeyCode.One] = "1", [Enum.KeyCode.Two] = "2", [Enum.KeyCode.Three] = "3",
	[Enum.KeyCode.Four] = "4", [Enum.KeyCode.Five] = "5", [Enum.KeyCode.Six] = "6",
	[Enum.KeyCode.Seven] = "7", [Enum.KeyCode.Eight] = "8", [Enum.KeyCode.Nine] = "9",
	[Enum.KeyCode.N] = "N", [Enum.KeyCode.T] = "T", [Enum.KeyCode.K] = "K",
	[Enum.KeyCode.H] = "H", [Enum.KeyCode.M] = "M", [Enum.KeyCode.R] = "R",
}

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	local key = HOTKEYS[input.KeyCode]
	if key then
		DebugHotkey:FireServer(key)
	end
end)
