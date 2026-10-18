-- Edit-time build script for the two game boards in Workspace.PatternCabinet: TargetBoard and LiveBoard.
-- Run it after build_pattern_cabinet.lua (which builds the entry pad and the table), and again
-- whenever the board look changes: it destroys both board Models and builds them fresh on the table.
-- Not part of the game: run it in Studio's command bar (or via the MCP execute_luau tool) in Edit mode.
-- Undo with Ctrl+Z.
--
-- Each board is one chunky raised wooden board: a solid Slab on the table, and on it a raised border
-- frame with a beveled outer edge, in a lighter warm wood than the table. Inside the frame the 12 cells
-- are inlaid wooden squares in two alternating tones (a chessboard, A1 dark), separated by thin dark
-- grooves. Row letters A-C (both side borders) and column numbers 1-4 (the row C border) are burned into
-- the frame, upright for someone standing on the row C side (-Z); TARGET / LIVE is inlaid in the row A
-- border in the board's accent color (gold / green), which also runs as a thin inlay line around the
-- squares and as a foot band around the slab. The LiveBoard's slab runs on toward +Z as an apron
-- carrying a clone of ReplicatedStorage.ArmTwin.
--
-- What game code relies on (keep it when restyling):
--   Base: exactly the grid's size in X and Z (Config.gridCols / gridRows x Config.boardCellStuds), no
--     rotation, the board's PrimaryPart. Grid.worldPositionOf lays the cells out on its top face: row A
--     at its +Z edge (the arm side), column 1 at its +X edge (so from the row C side the columns read
--     1 2 3 4 left to right, like the printed sheet). It is the dark groove color, so the gaps
--     between squares, and a vanished square (tile Transparency = 1, LiveBoard.setVanished), read as a
--     dark groove / hole.
--   Cell tiles A1..C4: on Base's top at Grid.worldPositionOf, turned +90 degrees, no SurfaceGui inside.
--     BlockPool stands each block on its tile's top face.
--   SpinClick ClickDetector on the TargetBoard Model only (the LiveBoard and its arm twin never spin,
--     like the real table), a Blocks Folder on the LiveBoard, the twin clone on the apron
--     Config.twinBaseOffsetMm from the grid's row A edge, centered on the board's width, its base on the
--     Slab top.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local cabinet = workspace:FindFirstChild("PatternCabinet")
assert(cabinet, "Workspace.PatternCabinet is not built; run build_pattern_cabinet.lua first")
local tableTopPart = cabinet:FindFirstChild("Table") and cabinet.Table:FindFirstChild("Top")
assert(tableTopPart, "PatternCabinet.Table.Top is missing")
local twinTemplate = ReplicatedStorage:FindFirstChild("ArmTwin")
assert(twinTemplate and twinTemplate:FindFirstChild("Base"), "ReplicatedStorage.ArmTwin is not built; run build_arm_twin.lua first")

-- Require a clone so edit-time require caching never hands back stale module code.
local PatternMatch = ReplicatedStorage.PatternMatch:Clone()
local Config = require(PatternMatch.Config)
local Grid = require(PatternMatch.Grid)

local CELL_PITCH = Config.boardCellStuds -- studs per cell (also the twin's mm -> stud scale)
local STUDS_PER_MM = CELL_PITCH / Config.cellSizeMm
local GROOVE = 0.2          -- dark groove between squares (and between the outer squares and the frame)
local TILE_THICKNESS = 0.2  -- inlaid squares; a vanished one leaves a hole this deep
local BASE_THICKNESS = 0.15 -- the dark groove layer the squares sit on
local SLAB_THICKNESS = 1.0  -- solid board body on the table
local FRAME_HEIGHT = 0.45   -- raised border above the slab top
local BORDER = 2.2          -- slab beyond the grid on every side (the frame plus its bevel)
local BEVEL = 0.35          -- run of the frame's outer chamfer
local INLAY_WIDTH = 0.12    -- accent line around the squares
local INLAY_OFFSET = 0.12   -- from the frame's inner edge
local FOOT_HEIGHT = 0.18    -- accent band around the slab's foot
local FOOT_LIP = 0.04       -- how far the band stands proud of the slab sides
local CARVE_PPS = 60        -- SurfaceGui pixels per stud for the burned-in text

-- Board centers: the old boards' Base X/Z when they exist (the cell geometry never moves), else the
-- positions build_pattern_cabinet.lua used.
local DEFAULT_CENTERS = { TargetBoard = Vector2.new(-11, -30), LiveBoard = Vector2.new(11, -30) }

-- Woods (all Enum.Material.Wood). The table is #7a5638; the boards are a lighter honey oak.
local FRAME_WOOD = Color3.fromHex("c28a52")  -- slab, frame, bevel
local LIGHT_SQUARE = Color3.fromHex("ead1a0") -- maple
local DARK_SQUARE = Color3.fromHex("9a643a")  -- cherry
local GROOVE_COLOR = Color3.fromHex("1c120b") -- Base and the groove well: near-black brown
local BURN = Color3.fromHex("2e1c10")         -- burned-in letters
local BURN_HIGHLIGHT = Color3.fromHex("e3b884") -- lit lower lip of each carved letter
local ACCENTS = {
	TargetBoard = { color = Color3.fromHex("d9a63a"), word = "TARGET" }, -- gold
	LiveBoard = { color = Color3.fromHex("3f9a58"), word = "LIVE" },     -- green
}
local FONT = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Heavy)

local tableTop = tableTopPart.Position.Y + tableTopPart.Size.Y / 2
local gridX = Config.gridCols * CELL_PITCH
local gridZ = Config.gridRows * CELL_PITCH
local twinOffset = Config.twinBaseOffsetMm * STUDS_PER_MM
local twinBaseDepth = twinTemplate.Base.Size.Z

local slabTop = tableTop + SLAB_THICKNESS
local baseTop = slabTop + BASE_THICKNESS
local tileTop = baseTop + TILE_THICKNESS
local frameTop = slabTop + FRAME_HEIGHT

local function part(className, name, size, cframe, color, parent, material)
	local p = Instance.new(className)
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Anchored = true
	p.Material = material or Enum.Material.Wood
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- One line of carved text. Two labels: a light copy nudged toward the viewer (the lit lower lip of the
-- cut) under the dark burned text.
local function carvedText(gui, text, color, props)
	local highlight = Instance.new("TextLabel")
	highlight.Name = "Highlight"
	highlight.BackgroundTransparency = 1
	highlight.Text = text
	highlight.TextScaled = true
	highlight.FontFace = FONT
	highlight.TextColor3 = BURN_HIGHLIGHT
	highlight.TextTransparency = 0.25
	highlight.Size = UDim2.fromScale(1, 1)
	highlight.Position = UDim2.fromScale(0, 0.035)
	highlight.Parent = gui
	local label = Instance.new("TextLabel")
	label.Name = "TextLabel"
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.FontFace = FONT
	label.TextColor3 = color
	label.Size = UDim2.fromScale(1, 1)
	for k, v in pairs(props or {}) do
		label[k] = v
	end
	label.Parent = gui
	return label
end

-- A Top-face text sheet lying on the frame, `width` along world X and `depth` along world Z. Turned +90
-- degrees: a Top SurfaceGui's up is the part's -X, which the turn points at world +Z, so the text reads
-- upright from the row C (-Z) side. The turn also swaps the part's local X and Z.
local function carving(parent, name, center, width, depth, text, color, props)
	local sheet = part("Part", name, Vector3.new(depth, 0.02, width),
		CFrame.new(center.X, frameTop + 0.01, center.Z) * CFrame.Angles(0, math.pi / 2, 0), FRAME_WOOD, parent, Enum.Material.SmoothPlastic)
	sheet.Transparency = 1
	sheet.CanCollide = false
	sheet.CanTouch = false
	sheet.CanQuery = false
	sheet.CastShadow = false
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = CARVE_PPS
	gui.LightInfluence = 1
	gui.Parent = sheet
	return carvedText(gui, text, color, props)
end

-- The angle (about Y) that points a CornerWedgePart's high corner, local (+X, -Z), along `dir`.
local function cornerWedgeAngle(dir)
	for quarter = 0, 3 do
		local angle = quarter * math.pi / 2
		local v = CFrame.Angles(0, angle, 0):VectorToWorldSpace(Vector3.new(1, 0, -1))
		if (v - dir).Magnitude < 0.01 then
			return angle
		end
	end
	error("no corner wedge angle")
end

local function buildBoard(name, center)
	local accent = ACCENTS[name]
	local x, z = center.X, center.Y
	local board = Instance.new("Model")
	board.Name = name

	-- Slab: the solid body. The LiveBoard's runs on toward +Z (the spawn) as an apron for the arm twin,
	-- so the twin stands on the board and spins with it.
	-- It ends 0.4 studs past the twin's base, which keeps it (and its foot band) on the table top.
	local apron = 0
	if name == "LiveBoard" then
		apron = twinOffset + twinBaseDepth / 2 + 0.4 - BORDER
	end
	local slabSize = Vector3.new(gridX + 2 * BORDER, SLAB_THICKNESS, gridZ + 2 * BORDER + apron)
	local slab = part("Part", "Slab", slabSize, CFrame.new(x, tableTop + SLAB_THICKNESS / 2, z + apron / 2), FRAME_WOOD, board)
	-- The word again on the slab's +Z face (the end the player walks up to), for the walk-up view.
	local frontGui = Instance.new("SurfaceGui")
	frontGui.Face = Enum.NormalId.Back
	frontGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	frontGui.PixelsPerStud = CARVE_PPS
	frontGui.LightInfluence = 1
	frontGui.Parent = slab
	carvedText(frontGui, accent.word, BURN, {
		Size = UDim2.fromScale(0.6, 0.7), Position = UDim2.fromScale(0.2, 0.08),
	})
	frontGui.Highlight.Size = UDim2.fromScale(0.6, 0.7)
	frontGui.Highlight.Position = UDim2.fromScale(0.2, 0.08 + 0.04)

	-- Accent foot band around the slab, just proud of its sides.
	local foot = part("Part", "FootTrim", Vector3.new(slabSize.X + 2 * FOOT_LIP, FOOT_HEIGHT, slabSize.Z + 2 * FOOT_LIP),
		CFrame.new(x, tableTop + FOOT_HEIGHT / 2, slab.Position.Z), accent.color, board, Enum.Material.Metal)
	foot.CanCollide = false

	-- Dark groove layer. Base is exactly the grid; the Well under it reaches the frame, so the groove
	-- between the outer squares and the frame is as dark (and as wide) as the ones between squares.
	local half = GROOVE / 2
	part("Part", "Well", Vector3.new(gridX + GROOVE, BASE_THICKNESS - 0.02, gridZ + GROOVE),
		CFrame.new(x, slabTop + (BASE_THICKNESS - 0.02) / 2, z), GROOVE_COLOR, board, Enum.Material.SmoothPlastic)
	local base = part("Part", "Base", Vector3.new(gridX, BASE_THICKNESS, gridZ),
		CFrame.new(x, slabTop + BASE_THICKNESS / 2, z), GROOVE_COLOR, board, Enum.Material.SmoothPlastic)

	-- Raised frame: four bars from the groove out to the bevel, the X-running bars covering the corners.
	local frameIn = half                 -- frame inner edge, beyond the grid edge
	local frameOut = BORDER - BEVEL      -- frame outer edge (top of the bevel), beyond the grid edge
	local barWidth = frameOut - frameIn
	local frameY = slabTop + FRAME_HEIGHT / 2
	local outerX = gridX / 2 + frameOut
	for _, sz in ipairs({ -1, 1 }) do
		part("Part", "Frame", Vector3.new(2 * outerX, FRAME_HEIGHT, barWidth),
			CFrame.new(x, frameY, z + sz * (gridZ / 2 + frameIn + barWidth / 2)), FRAME_WOOD, board)
	end
	for _, sx in ipairs({ -1, 1 }) do
		part("Part", "Frame", Vector3.new(barWidth, FRAME_HEIGHT, gridZ + 2 * frameIn),
			CFrame.new(x + sx * (gridX / 2 + frameIn + barWidth / 2), frameY, z), FRAME_WOOD, board)
	end

	-- Bevel: a wedge down each outer side of the frame to the slab's edge, and a corner wedge at each
	-- corner. A WedgePart is low at its -Z (front) face, so it faces its look direction.
	local outerZ = gridZ / 2 + frameOut
	local edges = {
		{ Vector3.new(0, 0, 1), 2 * outerX, z + outerZ + BEVEL / 2, x },
		{ Vector3.new(0, 0, -1), 2 * outerX, z - outerZ - BEVEL / 2, x },
		{ Vector3.new(1, 0, 0), 2 * outerZ, x + outerX + BEVEL / 2, z },
		{ Vector3.new(-1, 0, 0), 2 * outerZ, x - outerX - BEVEL / 2, z },
	}
	for _, edge in ipairs(edges) do
		local dir, length = edge[1], edge[2]
		local pos = dir.Z ~= 0 and Vector3.new(edge[4], frameY, edge[3]) or Vector3.new(edge[3], frameY, edge[4])
		part("WedgePart", "Bevel", Vector3.new(length, FRAME_HEIGHT, BEVEL), CFrame.lookAt(pos, pos + dir), FRAME_WOOD, board)
	end
	for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local sx, sz = corner[1], corner[2]
		local pos = Vector3.new(x + sx * (outerX + BEVEL / 2), frameY, z + sz * (outerZ + BEVEL / 2))
		-- The high corner points back toward the board's middle.
		local angle = cornerWedgeAngle(Vector3.new(-sx, 0, -sz))
		part("CornerWedgePart", "BevelCorner", Vector3.new(BEVEL, FRAME_HEIGHT, BEVEL),
			CFrame.new(pos) * CFrame.Angles(0, angle, 0), FRAME_WOOD, board)
	end

	-- Accent inlay line around the squares, set into the frame top.
	local inlayY = frameTop - 0.04
	local inlayIn = frameIn + INLAY_OFFSET
	local inlayMid = inlayIn + INLAY_WIDTH / 2
	for _, sz in ipairs({ -1, 1 }) do
		part("Part", "Inlay", Vector3.new(gridX + 2 * (inlayIn + INLAY_WIDTH), 0.1, INLAY_WIDTH),
			CFrame.new(x, inlayY, z + sz * (gridZ / 2 + inlayMid)), accent.color, board, Enum.Material.Metal)
	end
	for _, sx in ipairs({ -1, 1 }) do
		part("Part", "Inlay", Vector3.new(INLAY_WIDTH, 0.1, gridZ + 2 * inlayIn),
			CFrame.new(x + sx * (gridX / 2 + inlayMid), inlayY, z), accent.color, board, Enum.Material.Metal)
	end

	-- Burned-in row letters (both side borders) and column numbers (the row C border), in the frame
	-- between the inlay line and the bevel, centered on their row / column.
	local textIn = inlayIn + INLAY_WIDTH + 0.05
	local textDepth = frameOut - textIn - 0.05
	local textMid = textIn + textDepth / 2
	for row = 1, Config.gridRows do
		local letter = string.sub(Grid.cellName(row, 1), 1, 1)
		local rowZ = z + (0.5 - (row - 0.5) / Config.gridRows) * gridZ
		for _, sx in ipairs({ -1, 1 }) do
			carving(board, "RowLabel", Vector3.new(x + sx * (gridX / 2 + textMid), 0, rowZ), textDepth, textDepth, letter, BURN)
		end
	end
	for col = 1, Config.gridCols do
		local colX = x + (0.5 - (col - 0.5) / Config.gridCols) * gridX -- column 1 at +X, like Grid
		carving(board, "ColumnLabel", Vector3.new(colX, 0, z - gridZ / 2 - textMid), textDepth, textDepth, tostring(col), BURN)
	end
	-- TARGET / LIVE in the row A border, inlaid in the accent color.
	local word = carving(board, "BoardLabel", Vector3.new(x, 0, z + gridZ / 2 + textMid), gridX * 0.6, textDepth, accent.word, accent.color)
	local stroke = Instance.new("UIStroke")
	stroke.Color = BURN
	stroke.Thickness = 2
	stroke.Parent = word

	-- Inlaid squares, chessboard: A1 (row + column even) dark.
	for _, cell in ipairs(Grid.allCells()) do
		local row, col = Grid.parseCell(cell)
		local pos = Grid.worldPositionOf(cell, base)
		local cframe = (base.CFrame.Rotation + pos + base.CFrame.UpVector * (TILE_THICKNESS / 2)) * CFrame.Angles(0, math.pi / 2, 0)
		local color = (row + col) % 2 == 0 and DARK_SQUARE or LIGHT_SQUARE
		part("Part", cell, Vector3.new(CELL_PITCH - GROOVE, TILE_THICKNESS, CELL_PITCH - GROOVE), cframe, color, board)
	end

	if name == "LiveBoard" then
		local twin = twinTemplate:Clone()
		for _, child in ipairs(twin:GetChildren()) do
			if child:IsA("LuaSourceContainer") then
				child:Destroy() -- the Rig and Driver modules stay on the template only
			end
		end
		-- On the apron, Config.twinBaseOffsetMm from the grid's row A edge, centered on the board's width.
		twin:PivotTo(CFrame.new(x, slabTop, z + gridZ / 2 + twinOffset))
		twin.Parent = board

		local blocks = Instance.new("Folder")
		blocks.Name = "Blocks"
		blocks.Parent = board
	end

	-- TargetBoard only: click anywhere on it to spin it (ServerScriptService.PatternMode). On the Model
	-- rather than the Base alone, because the tiles cover the Base's top. The LiveBoard stays fixed.
	if name == "TargetBoard" then
		local spinClick = Instance.new("ClickDetector")
		spinClick.Name = "SpinClick"
		spinClick.MaxActivationDistance = 40
		spinClick.Parent = board
	end
	board.PrimaryPart = base
	return board
end

local recording = ChangeHistoryService:TryBeginRecording("Build PatternBoards")

local built = {}
for _, name in ipairs({ "TargetBoard", "LiveBoard" }) do
	local center = DEFAULT_CENTERS[name]
	local old = cabinet:FindFirstChild(name)
	if old then
		local oldBase = old:FindFirstChild("Base")
		if oldBase then
			center = Vector2.new(oldBase.Position.X, oldBase.Position.Z)
		end
		old:Destroy()
	end
	local board = buildBoard(name, center)
	board.Parent = cabinet
	table.insert(built, string.format("%s at (%.2f, %.2f): %d descendants", name, center.X, center.Y, #board:GetDescendants()))
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
return string.format("table top %.3f, Base top %.3f, tile top %.3f, frame top %.3f; %s",
	tableTop, baseTop, tileTop, frameTop, table.concat(built, "; "))
