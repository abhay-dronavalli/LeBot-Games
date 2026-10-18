-- Edit-time build script for Workspace.PatternCabinet, styled after the Apprentice 3D view
-- (github.com/NSang22/apprentice, ui/view3d.js): one wooden table on a rough floating island, two thin
-- wooden board slabs on it, each with a printed paper grid sheet (black grid lines, gray cell labels,
-- AprilTag-style corner squares), the Entry pad with the "Play Pattern Match" prompt, and a clone of
-- ReplicatedStorage.ArmTwin on the LiveBoard's wooden apron. Also stores the rounded-cube block mesh as
-- ReplicatedStorage.PatternMatch.BlockMesh (PatternMatch.BlockPool clones it) and sets the warm-key /
-- cool-fill lighting.
-- Not part of the game: run it once in Studio's command bar (or via the MCP execute_luau tool), after
-- build_arm_twin.lua. Refuses to run if PatternCabinet already exists. Undo with Ctrl+Z.
-- Lighting.Technology can't be set from a script without plugin permissions: set it to Future by hand
-- in the Properties panel so blocks cast soft shadows on the paper.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local InsertService = game:GetService("InsertService")
local Lighting = game:GetService("Lighting")

assert(not workspace:FindFirstChild("PatternCabinet"), "Workspace.PatternCabinet already exists")
local twinTemplate = ReplicatedStorage:FindFirstChild("ArmTwin")
assert(twinTemplate and twinTemplate:FindFirstChild("Base"), "ReplicatedStorage.ArmTwin is not built; run build_arm_twin.lua first")

-- Require a clone so edit-time require caching never hands back stale module code.
local PatternMatch = ReplicatedStorage.PatternMatch:Clone()
local Config = require(PatternMatch.Config)
local Grid = require(PatternMatch.Grid)

local CELL_PITCH = Config.boardCellStuds -- studs per cell on the boards (also the twin's cm -> stud scale)
local STUDS_PER_CM = CELL_PITCH / Config.cellSizeCm
local CELL_GAP = 0.2         -- studs between cell tiles: the black grid line width
local LAYER = 0.1            -- thickness of the paper, the ink layer and the cell tiles
local PAPER_MARGIN = 0.8     -- paper beyond the grid on every side (room for the corner tags)
local SLAB_MARGIN = 1.0      -- wooden slab beyond the grid
local SLAB_THICKNESS = 0.7
local TABLE_THICKNESS = 0.6
local TABLE_HEIGHT = 2.6     -- floor to table top
local BOARD_SPACING = 22     -- studs between board centers
local TAG_SIZE = 0.7         -- corner tag squares on the paper
local BLOCK_MESH_ASSET = 6416975593 -- Creator Store "Rounded Cube" (Plex Studios), free

-- Apprentice palette
local WOOD = Color3.fromHex("7a5638")
local WOOD_EDGE = Color3.fromHex("5f4129")  -- slab edges: a shade darker than the table
local PAPER = Color3.fromHex("f7f6f2")
local INK = Color3.fromHex("111111")
local LABEL = Color3.fromHex("555555")
local FAINT = Color3.fromHex("8a8a8a")
local WOOD_TEXT = Color3.fromHex("1e1812")

local baseplate = workspace:FindFirstChild("Baseplate")
local groundY = baseplate and baseplate.Position.Y + baseplate.Size.Y / 2 or 0
local center = Vector3.new(0, groundY, -27) -- floor center; the boards sit a little behind it

local function part(name, size, cframe, color, parent, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Anchored = true
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function surface(parent, face, props)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = props and props.PixelsPerStud or 50
	gui.Parent = parent
	return gui
end

local function label(parent, face, text, props)
	local gui = surface(parent, face)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.Font = Enum.Font.GothamBold
	t.TextColor3 = WOOD_TEXT
	t.Size = UDim2.fromScale(1, 1)
	for k, v in pairs(props or {}) do
		t[k] = v
	end
	t.Parent = gui
	return t
end

-- The rounded-cube MeshPart the BlockPool clones. Reuses an existing one, else loads it from the store.
local function ensureBlockMesh()
	local existing = ReplicatedStorage.PatternMatch:FindFirstChild("BlockMesh")
	if existing then
		return existing, "kept"
	end
	local ok, loaded = pcall(InsertService.LoadAsset, InsertService, BLOCK_MESH_ASSET)
	local mesh = ok and loaded and loaded:FindFirstChildWhichIsA("MeshPart", true)
	if not mesh then
		if loaded then loaded:Destroy() end
		return nil, "unavailable (" .. tostring(loaded) .. "); BlockPool falls back to plain Parts"
	end
	mesh.Name = "BlockMesh"
	for _, child in ipairs(mesh:GetChildren()) do child:Destroy() end
	mesh.TextureID = ""
	mesh.Size = Vector3.one
	mesh.CFrame = CFrame.new()
	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.CanTouch = false
	mesh.CanQuery = false
	mesh.Material = Enum.Material.SmoothPlastic
	mesh.Color = PAPER
	mesh.Parent = ReplicatedStorage.PatternMatch
	loaded:Destroy()
	return mesh, "loaded from asset " .. BLOCK_MESH_ASSET
end

-- AprilTag-style corner square: black with a 4x4 pattern of white modules inside a black border.
local TAG_PATTERNS = {
	{ 1,0,1,1, 0,1,0,0, 1,1,0,1, 0,0,1,0 },
	{ 0,1,1,0, 1,0,0,1, 1,1,0,0, 0,1,0,1 },
	{ 1,1,0,1, 0,0,1,0, 0,1,1,0, 1,0,0,1 },
	{ 0,1,0,1, 1,1,0,0, 0,0,1,1, 1,0,1,0 },
}
local function tag(parent, cframe, pattern)
	local square = part("Tag", Vector3.new(TAG_SIZE, LAYER / 2, TAG_SIZE), cframe, INK, parent)
	local gui = surface(square, Enum.NormalId.Top, { PixelsPerStud = 200 })
	for i, bit in ipairs(pattern) do
		if bit == 1 then
			local module = Instance.new("Frame")
			module.BorderSizePixel = 0
			module.BackgroundColor3 = PAPER
			module.Size = UDim2.fromScale(1 / 6, 1 / 6)
			module.Position = UDim2.fromScale((1 + (i - 1) % 4) / 6, (1 + math.floor((i - 1) / 4)) / 6)
			module.Parent = gui
		end
	end
	return square
end

local recording = ChangeHistoryService:TryBeginRecording("Build PatternCabinet")

local blockMesh, blockMeshNote = ensureBlockMesh()

local cabinet = Instance.new("Model")
cabinet.Name = "PatternCabinet"

local floor = part("Floor", Vector3.new(48, 1, 36), CFrame.new(center + Vector3.new(0, 0.5, 0)),
	Color3.fromRGB(150, 140, 120), cabinet)
local floorTop = floor.Position.Y + floor.Size.Y / 2

-- Island: a rough grass and rock mass under the floor. The Baseplate hides it in normal play; the mode
-- select shot hides the Baseplate on the chooser's client, so the cabinet floats in open sky.
local island = Instance.new("Model")
island.Name = "Island"
island.Parent = cabinet
local ISLAND_LAYERS = { -- size, depth of its top below the floor, color, material, turn (deg), x/z nudge
	{ Vector3.new(52, 2, 40), 0.2, Color3.fromRGB(88, 148, 68), Enum.Material.Grass, 0, 0, 0 },
	{ Vector3.new(46, 5, 34), 2.2, Color3.fromRGB(112, 102, 90), Enum.Material.Rock, 4, 1, -1 },
	{ Vector3.new(34, 5, 24), 7.2, Color3.fromRGB(100, 90, 80), Enum.Material.Rock, -6, -1.5, 1 },
	{ Vector3.new(22, 5, 14), 12.2, Color3.fromRGB(90, 80, 70), Enum.Material.Rock, 9, 2, -1.5 },
	{ Vector3.new(10, 4, 6), 17.2, Color3.fromRGB(80, 72, 64), Enum.Material.Rock, -3, -1, 0.5 },
}
for i, layer in ipairs(ISLAND_LAYERS) do
	local size, depth, color, material, turn, dx, dz = table.unpack(layer)
	local top = groundY - depth
	local rock = part("Layer" .. i, size,
		CFrame.new(center.X + dx, top - size.Y / 2, center.Z + dz) * CFrame.Angles(0, math.rad(turn), 0), color, island)
	rock.Material = material
	rock.CanCollide = false
	rock.CanQuery = false
	rock.CanTouch = false
end

-- Entry pad between the spawn and the table. ServerScriptService.PatternMode listens to its prompt.
local entry = part("Entry", Vector3.new(4, 0.4, 4), CFrame.new(center.X, floorTop + 0.2, center.Z + 16),
	Color3.fromRGB(70, 170, 90), cabinet)
local prompt = Instance.new("ProximityPrompt")
prompt.Name = "PlayPrompt"
prompt.ActionText = "Play Pattern Match"
prompt.ObjectText = "Pattern Match"
prompt.HoldDuration = 0
prompt.MaxActivationDistance = 8
prompt.RequiresLineOfSight = false
prompt.Parent = entry

-- One wooden table for both boards: a top slab on four legs. The boards' row A edge faces the spawn (+Z).
local boardZ = center.Z - 3
local tableTop = floorTop + TABLE_HEIGHT
local tableModel = Instance.new("Model")
tableModel.Name = "Table"
local tableSize = Vector3.new(46, TABLE_THICKNESS, 31)
local tableCenterZ = boardZ + 0.5
part("Top", tableSize, CFrame.new(center.X, tableTop - TABLE_THICKNESS / 2, tableCenterZ), WOOD, tableModel, Enum.Material.Wood)
local legHeight = TABLE_HEIGHT - TABLE_THICKNESS
for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
	part("Leg", Vector3.new(1.2, legHeight, 1.2),
		CFrame.new(center.X + corner[1] * (tableSize.X / 2 - 2), floorTop + legHeight / 2, tableCenterZ + corner[2] * (tableSize.Z / 2 - 2)),
		WOOD, tableModel, Enum.Material.Wood)
end
tableModel.Parent = cabinet

local gridSize = Vector3.new(Config.gridCols * CELL_PITCH, LAYER, Config.gridRows * CELL_PITCH)
local twinOffset = Config.twinBaseOffsetCm * STUDS_PER_CM
local twinBaseDepth = twinTemplate.Base.Size.Z

for i, spec in ipairs({ { "TargetBoard", "TARGET" }, { "LiveBoard", "LIVE" } }) do
	local board = Instance.new("Model")
	board.Name = spec[1]
	local x = center.X + (i - 1.5) * BOARD_SPACING

	-- Wooden slab. The LiveBoard's runs on toward the spawn as an apron for the arm twin, so the twin
	-- stands on the board and spins with it.
	local apron = 0
	if spec[1] == "LiveBoard" then
		apron = math.ceil(twinOffset + twinBaseDepth / 2 + 0.5)
	end
	local slabSize = Vector3.new(gridSize.X + 2 * SLAB_MARGIN, SLAB_THICKNESS, gridSize.Z + 2 * SLAB_MARGIN + apron)
	local slab = part("Slab", slabSize, CFrame.new(x, tableTop + SLAB_THICKNESS / 2, boardZ + apron / 2), WOOD_EDGE, board, Enum.Material.Wood)
	label(slab, Enum.NormalId.Back, spec[2], { TextColor3 = WOOD_TEXT }) -- +Z face: the row A edge, facing the spawn

	-- Paper sheet, then the black ink layer the cells sit on: the gaps between cell tiles show the ink,
	-- which draws the grid lines. Base is the ink layer, exactly the grid's size, because
	-- Grid.worldPositionOf lays the cells out from Base.Size; its +Z face is the row A edge (arm side)
	-- and column 1 (the tag 0 side) is at its -X end.
	local paperTop = tableTop + SLAB_THICKNESS + LAYER
	-- Turned +90 degrees like the cells, so its Top-face text reads upright from the row C side (a Top
	-- SurfaceGui's up is the part's -X, so after the turn it is world +Z); its local X and Z are swapped
	-- for the same reason. The arm-side note then sits in the row A margin, the top of the sheet for
	-- that viewer.
	local paper = part("Paper", Vector3.new(gridSize.Z + 2 * PAPER_MARGIN, LAYER, gridSize.X + 2 * PAPER_MARGIN),
		CFrame.new(x, paperTop - LAYER / 2, boardZ) * CFrame.Angles(0, math.pi / 2, 0), PAPER, board)
	label(paper, Enum.NormalId.Top, "ARM SIDE", {
		Font = Enum.Font.GothamMedium, TextColor3 = FAINT,
		Size = UDim2.fromScale(0.3, 0.6 / paper.Size.X), Position = UDim2.fromScale(0.35, 0.1 / paper.Size.X),
	})
	local base = part("Base", gridSize, CFrame.new(x, paperTop + LAYER / 2, boardZ), INK, board)
	for corner, pattern in ipairs(TAG_PATTERNS) do
		local sx = corner % 2 == 0 and 1 or -1
		local sz = corner > 2 and 1 or -1
		tag(board, CFrame.new(x + sx * (paper.Size.Z / 2 - TAG_SIZE / 2 - 0.05), paperTop + LAYER / 4,
			boardZ + sz * (paper.Size.X / 2 - TAG_SIZE / 2 - 0.05)) * CFrame.Angles(0, math.pi / 2, 0), pattern)
	end

	if spec[1] == "LiveBoard" then
		local twin = twinTemplate:Clone()
		for _, child in ipairs(twin:GetChildren()) do
			if child:IsA("LuaSourceContainer") then
				child:Destroy() -- the Rig and Driver modules stay on the template only
			end
		end
		-- On the apron, Config.twinBaseOffsetCm from the grid's row A edge, centered on the board's width.
		twin:PivotTo(CFrame.new(x, tableTop + SLAB_THICKNESS, boardZ + gridSize.Z / 2 + twinOffset))
		twin.Parent = board
	end

	for _, cell in ipairs(Grid.allCells()) do
		local pos = Grid.worldPositionOf(cell, base)
		-- Turned +90 degrees so the Top-face label reads upright from the row C side (the tripod side).
		local cframe = (base.CFrame.Rotation + pos + base.CFrame.UpVector * (LAYER / 2)) * CFrame.Angles(0, math.pi / 2, 0)
		local tile = part(cell, Vector3.new(CELL_PITCH - CELL_GAP, LAYER, CELL_PITCH - CELL_GAP), cframe, PAPER, board)
		-- Small gray label in the cell's top-left corner, as seen from the row C side.
		label(tile, Enum.NormalId.Top, cell, {
			Font = Enum.Font.GothamMedium, TextColor3 = LABEL,
			Size = UDim2.fromScale(0.3, 0.17), Position = UDim2.fromScale(0.06, 0.05),
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
		})
	end

	if spec[1] == "LiveBoard" then
		local blocks = Instance.new("Folder")
		blocks.Name = "Blocks"
		blocks.Parent = board
	end
	-- Click anywhere on the board to spin it (ServerScriptService.PatternMode). On the Model rather than
	-- the Base alone, because the tiles cover the Base's top.
	local spinClick = Instance.new("ClickDetector")
	spinClick.Name = "SpinClick"
	spinClick.MaxActivationDistance = 40
	spinClick.Parent = board
	board.PrimaryPart = base
	board.Parent = cabinet
end

cabinet.Parent = workspace

-- Lighting: warm key (the sun, mid-afternoon, from the player's front-left), slightly cool fill, soft
-- shadows. Technology = Future has to be set by hand (see the header).
local techOk = pcall(function() Lighting.Technology = Enum.Technology.Future end)
Lighting.ClockTime = 14.8
Lighting.GeographicLatitude = 30
Lighting.Brightness = 2.4
Lighting.ColorShift_Top = Color3.fromRGB(255, 238, 216)   -- sunlit faces: warm
Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
Lighting.Ambient = Color3.fromRGB(118, 128, 148)          -- shade: a touch cool
Lighting.OutdoorAmbient = Color3.fromRGB(132, 142, 162)
Lighting.ShadowSoftness = 0.6
Lighting.EnvironmentDiffuseScale = 0.5
Lighting.EnvironmentSpecularScale = 0.35
Lighting.ExposureCompensation = 0.15
Lighting.GlobalShadows = true

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
return string.format("built %s with %d descendants; block mesh %s; Lighting.Technology %s; sun direction %s",
	cabinet:GetFullName(), #cabinet:GetDescendants(), blockMeshNote, techOk and "set to Future" or "NOT set (set it by hand)",
	tostring(Lighting:GetSunDirection()))
