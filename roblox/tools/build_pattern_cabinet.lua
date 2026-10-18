-- Edit-time build script for Workspace.PatternCabinet: the Entry pad with the "Play Pattern Match"
-- prompt and one wooden table (Apprentice wood, #7a5638) that both game boards sit on. Also stores the
-- rounded-cube block mesh as ReplicatedStorage.PatternMatch.BlockMesh (PatternMatch.BlockPool clones it).
-- Not part of the game: run it in Studio's command bar (or via the MCP execute_luau tool). Order for a
-- fresh place: build_arm_twin.lua, build_room.lua (the bedroom, its floor top at Y = 1), this script,
-- build_pattern_boards.lua (TargetBoard, LiveBoard and the arm twin clone), setup_lighting.lua.
-- Refuses to run if PatternCabinet already exists. Undo with Ctrl+Z.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local InsertService = game:GetService("InsertService")

assert(not workspace:FindFirstChild("PatternCabinet"), "Workspace.PatternCabinet already exists")

local FLOOR_TOP = 1.0         -- the bedroom floor's top surface (tools/build_room.lua)
local TABLE_THICKNESS = 0.6
local TABLE_HEIGHT = 2.6      -- floor to table top
local BLOCK_MESH_ASSET = 6416975593 -- Creator Store "Rounded Cube" (Plex Studios), free
local WOOD = Color3.fromHex("7a5638")
local center = Vector3.new(0, FLOOR_TOP, -27) -- the boards sit a little behind this point

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
	mesh.Color = Color3.new(1, 1, 1)
	mesh.Parent = ReplicatedStorage.PatternMatch
	loaded:Destroy()
	return mesh, "loaded from asset " .. BLOCK_MESH_ASSET
end

local recording = ChangeHistoryService:TryBeginRecording("Build PatternCabinet")

local _, blockMeshNote = ensureBlockMesh()

local cabinet = Instance.new("Model")
cabinet.Name = "PatternCabinet"

-- Entry pad between the spawn and the table. ServerScriptService.PatternMode listens to its prompt.
local entry = part("Entry", Vector3.new(4, 0.4, 4), CFrame.new(center.X, FLOOR_TOP + 0.2, center.Z + 16),
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
local tableTop = FLOOR_TOP + TABLE_HEIGHT
local tableModel = Instance.new("Model")
tableModel.Name = "Table"
local tableSize = Vector3.new(46, TABLE_THICKNESS, 31)
local tableCenterZ = center.Z - 2.5
part("Top", tableSize, CFrame.new(center.X, tableTop - TABLE_THICKNESS / 2, tableCenterZ), WOOD, tableModel, Enum.Material.Wood)
local legHeight = TABLE_HEIGHT - TABLE_THICKNESS
for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
	part("Leg", Vector3.new(1.2, legHeight, 1.2),
		CFrame.new(center.X + corner[1] * (tableSize.X / 2 - 2), FLOOR_TOP + legHeight / 2, tableCenterZ + corner[2] * (tableSize.Z / 2 - 2)),
		WOOD, tableModel, Enum.Material.Wood)
end
tableModel.Parent = cabinet

-- The TargetBoard and LiveBoard Models (wooden boards, inlaid squares, the arm twin clone) are built by
-- tools/build_pattern_boards.lua: run it next, after this script.

cabinet.Parent = workspace

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
return string.format("built %s with %d descendants; block mesh %s", cabinet:GetFullName(), #cabinet:GetDescendants(), blockMeshNote)
