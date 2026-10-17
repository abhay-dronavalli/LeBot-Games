-- Edit-time build script for Workspace.PatternCabinet (placeholder floor, Entry pad with the
-- "Play Pattern Match" prompt, TargetBoard, LiveBoard).
-- Not part of the game: run it once in Studio's command bar (or via the MCP execute_luau tool).
-- Refuses to run if PatternCabinet already exists. Undo with Ctrl+Z.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

assert(not workspace:FindFirstChild("PatternCabinet"), "Workspace.PatternCabinet already exists")

-- Require a clone so edit-time require caching never hands back stale module code.
local PatternMatch = ReplicatedStorage.PatternMatch:Clone()
local Config = require(PatternMatch.Config)
local Grid = require(PatternMatch.Grid)

local CELL_PITCH = 4         -- studs per cell on the boards
local CELL_GAP = 0.3         -- studs between neighboring cell tiles
local CELL_THICKNESS = 0.2
local STAND_HEIGHT = 2.5
local BOARD_SPACING = 20     -- studs between board centers
local NEUTRAL = Color3.fromRGB(200, 200, 200)

local baseplate = workspace:FindFirstChild("Baseplate")
local groundY = baseplate and baseplate.Position.Y + baseplate.Size.Y / 2 or 0
local center = Vector3.new(0, groundY, -30)

local function part(name, size, cframe, color, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Anchored = true
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function label(parent, face, text, props)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.Font = Enum.Font.GothamBold
	t.TextColor3 = Color3.new(0, 0, 0)
	t.Size = UDim2.fromScale(1, 1)
	for k, v in pairs(props or {}) do
		t[k] = v
	end
	t.Parent = gui
	gui.Parent = parent
end

local recording = ChangeHistoryService:TryBeginRecording("Build PatternCabinet")

local cabinet = Instance.new("Model")
cabinet.Name = "PatternCabinet"

local floor = part("Floor", Vector3.new(44, 1, 26), CFrame.new(center + Vector3.new(0, 0.5, 0)),
	Color3.fromRGB(150, 140, 120), cabinet)
local floorTop = floor.Position.Y + floor.Size.Y / 2

-- Entry pad between the spawn and the boards. ServerScriptService.PatternMode listens to its prompt.
local entry = part("Entry", Vector3.new(4, 0.4, 4), CFrame.new(center.X, floorTop + 0.2, center.Z + 10),
	Color3.fromRGB(70, 170, 90), cabinet)
local prompt = Instance.new("ProximityPrompt")
prompt.Name = "PlayPrompt"
prompt.ActionText = "Play Pattern Match"
prompt.ObjectText = "Pattern Match"
prompt.HoldDuration = 0
prompt.MaxActivationDistance = 8
prompt.RequiresLineOfSight = false
prompt.Parent = entry

for i, spec in ipairs({ { "TargetBoard", "TARGET" }, { "LiveBoard", "LIVE" } }) do
	local board = Instance.new("Model")
	board.Name = spec[1]
	local x = center.X + (i - 1.5) * BOARD_SPACING
	local baseSize = Vector3.new(Config.gridCols * CELL_PITCH, 1, Config.gridRows * CELL_PITCH)

	part("Stand", Vector3.new(baseSize.X - 2, STAND_HEIGHT, baseSize.Z - 2),
		CFrame.new(x, floorTop + STAND_HEIGHT / 2, center.Z), Color3.fromRGB(90, 90, 90), board)
	local base = part("Base", baseSize, CFrame.new(x, floorTop + STAND_HEIGHT + baseSize.Y / 2, center.Z),
		Color3.fromRGB(45, 45, 45), board)
	-- Base's +Z face is the row A edge (arm side, where the arm twin will sit), facing the spawn.
	-- Column 1 (tag 0 side) is at the -X end. Grid.worldPositionOf owns this layout.
	label(base, Enum.NormalId.Back, spec[2] .. "   (row A edge, arm side)", { TextColor3 = Color3.new(1, 1, 1) })

	for _, cell in ipairs(Grid.allCells()) do
		local pos = Grid.worldPositionOf(cell, base)
		-- Turned -90 degrees so the Top-face label reads upright from the row A edge.
		local cframe = (base.CFrame.Rotation + pos + base.CFrame.UpVector * (CELL_THICKNESS / 2))
			* CFrame.Angles(0, -math.pi / 2, 0)
		local tile = part(cell, Vector3.new(CELL_PITCH - CELL_GAP, CELL_THICKNESS, CELL_PITCH - CELL_GAP),
			cframe, NEUTRAL, board)
		-- Front-left corner, so a live block on the cell doesn't hide it.
		label(tile, Enum.NormalId.Top, cell, {
			Size = UDim2.fromScale(0.4, 0.2),
			Position = UDim2.fromScale(0.03, 0.78),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
		})
	end

	if spec[1] == "LiveBoard" then
		local blocks = Instance.new("Folder")
		blocks.Name = "Blocks"
		blocks.Parent = board
	end
	board.PrimaryPart = base
	board.Parent = cabinet
end

cabinet.Parent = workspace
if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
return "built " .. cabinet:GetFullName() .. " with " .. #cabinet:GetDescendants() .. " descendants"
