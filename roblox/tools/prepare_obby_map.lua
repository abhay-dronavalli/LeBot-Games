-- Packs Kushagra's obby course into one Model for the arcade (docs/obby-mode-plan.md "Getting the map in").
-- Run it in lebot_obby/Place1.rbxl (his standalone place), in EDIT mode, from the command bar:
--
--   1. From the repo root:  python -m http.server 8771 --bind 127.0.0.1
--   2. Studio command bar (Place1.rbxl open):
--        game:GetService("HttpService").HttpEnabled = true
--        loadstring(game:GetService("HttpService"):GetAsync("http://127.0.0.1:8771/roblox/tools/prepare_obby_map.lua"))()
--      (or paste this file into the command bar)
--   3. Right click Workspace.Map -> Save to File... -> places/ObbyMap.rbxm. Close Place1 WITHOUT saving, so
--      his standalone place keeps working.
--   4. Arcade place: right click ServerStorage.Modes.Obby -> Insert from File... -> places/ObbyMap.rbxm (it
--      arrives as Map), then run roblox/tools/install_obby_mode.lua, which checks it.
--
-- What it does, all inside one Model, Workspace.Map:
--   * moves Workspace.Warehouse and Workspace.Backdrop into it (the SkyArmRig is NOT taken: the SkyArm module
--     builds it at runtime, inside the map)
--   * turns every SpawnLocation in it into a plain Part (a SpawnLocation in the map would respawn arcade
--     players into the obby) and adds Map.Start (an invisible marker on the spawn pad: where Module.Start puts
--     the runners, facing down the course)
--   * adds Map.Finish: an invisible zone across the finale deck, past bay 4's exit door. Standing in it with
--     bay 4 solved wins the run
--   * adds Map.LobbyPad: the arcade's Back to Lobby pad (tagged LobbyTeleporter, Enabled attribute; the
--     arcade styles it) on the entrance deck, off to the side of the start and the bay 1 approach
--   * moves the whole Model ORIGIN_Z studs down +Z (a pure Z shift: the code assumes X 0..32 and adds
--     Config.OriginZ to every Z it computes), and sets ModelStreamingMode = Persistent
-- Safe to run again: a Map that already carries the OriginZ attribute is not moved twice.

local CollectionService = game:GetService("CollectionService")

local ORIGIN_Z = 1100 -- must equal ReplicatedStorage.Obby.Config.OriginZ in the arcade (roblox/ReplicatedStorage/Obby/Config.lua)

-- Place1's Config, read from SOURCE (the command bar caches required modules; build/fit_shell.lua does the same).
local function configNumber(name, fallback)
	local config = game.ReplicatedStorage:FindFirstChild("Config")
	local src = config and config:IsA("ModuleScript") and config.Source or ""
	local v = src:match("[\r\n]Config%." .. name .. "%s*=%s*(%-?[%d%.]+)")
	return tonumber(v) or fallback
end
local CELL = configNumber("CellSize", 8)
local COLS = configNumber("BayCols", 4)
local DEPTH = CELL * configNumber("BayRows", 3)             -- 24
local PITCH = DEPTH + configNumber("BayGap", 6)             -- 30
local NUM_BAYS = configNumber("NumBays", 4)
local WIDTH = CELL * COLS                                    -- 32
local ENTRANCE = configNumber("EntranceBuffer", 10)
local FINALE = configNumber("FinaleBuffer", 10)
local COURSE_END = (NUM_BAYS - 1) * PITCH + DEPTH            -- 114: bay 4's far wall / exit door

local report = {}
local function note(fmt, ...)
	table.insert(report, string.format(fmt, ...))
end

local map = workspace:FindFirstChild("Map")
if map and map:GetAttribute("OriginZ") ~= nil then
	print(string.format("[prepare_obby_map] Workspace.Map is already packed at OriginZ %s; nothing to do",
		tostring(map:GetAttribute("OriginZ"))))
	return
end
if not map then
	map = Instance.new("Model")
	map.Name = "Map"
	map.Parent = workspace
end
map.WorldPivot = CFrame.new() -- everything was built around the world origin

for _, name in ipairs({ "Warehouse", "Backdrop" }) do
	local inst = workspace:FindFirstChild(name)
	if inst then
		inst.Parent = map
		note("moved Workspace.%s into the Map", name)
	elseif not map:FindFirstChild(name) then
		warn("[prepare_obby_map] Workspace." .. name .. " is missing")
	end
end
-- The course spawn (Workspace.StartSpawn, (16, -0.5, -5) on the entrance deck) sits at the top of Workspace;
-- it comes along and is turned into a plain part below.
for _, child in ipairs(workspace:GetChildren()) do
	if child:IsA("SpawnLocation") then
		child.Parent = map
		note("moved Workspace.%s into the Map", child.Name)
	end
end
local rig = workspace:FindFirstChild("SkyArmRig")
if rig then
	note("left Workspace.SkyArmRig out (SkyArm rebuilds it inside the map at runtime)")
end

-- The surface under (x, z), looking only at the map: the floor the markers stand on.
local function floorY(x, z, fallback)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	params.RespectCanCollide = true -- skip the overhead rail beams (CanCollide off) and land on the deck
	local hit = workspace:Raycast(Vector3.new(x, 40, z), Vector3.new(0, -80, 0), params)
	return hit and hit.Position.Y or fallback
end

-- SpawnLocations -> plain parts; the first one marks the start.
local spawnAt = nil
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("SpawnLocation") then
		local pad = Instance.new("Part")
		pad.Name = d.Name == "SpawnLocation" and "SpawnPad" or d.Name
		for _, prop in ipairs({ "Size", "CFrame", "Color", "Material", "Transparency", "Reflectance", "TopSurface",
			"BottomSurface", "CastShadow", "Anchored", "CanCollide", "CanQuery", "CanTouch" }) do
			pad[prop] = d[prop]
		end
		for _, child in ipairs(d:GetChildren()) do
			if not child:IsA("Decal") or child.Name ~= "Decal" then -- the stock spawn decal goes
				child.Parent = pad
			end
		end
		for _, tag in ipairs(CollectionService:GetTags(d)) do
			CollectionService:AddTag(pad, tag)
		end
		for key, value in pairs(d:GetAttributes()) do
			pad:SetAttribute(key, value)
		end
		pad.Parent = d.Parent
		spawnAt = spawnAt or (d.Position + Vector3.new(0, d.Size.Y / 2, 0))
		note("SpawnLocation %s -> plain Part %s", d:GetFullName(), pad.Name)
		d:Destroy()
	end
end
if not spawnAt then
	local z = -ENTRANCE / 2
	spawnAt = Vector3.new(WIDTH / 2, floorY(WIDTH / 2, z, 0), z)
	note("no SpawnLocation in the map: Start goes on the entrance deck at (%.0f, %.1f, %.0f)", spawnAt.X, spawnAt.Y, spawnAt.Z)
end

local function marker(name, size, position, props)
	local old = map:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = CFrame.lookAt(position, position + Vector3.new(0, 0, 1)) -- facing down the course (+Z)
	p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow = false, false, false, false
	p.Transparency = 1
	for k, v in pairs(props or {}) do
		p[k] = v
	end
	p.Parent = map
	return p
end

-- Start: a flat marker on the spawn pad's top (RunControl.startCFrame stands runners 3.5 studs over it).
marker("Start", Vector3.new(4, 0.2, 4), spawnAt + Vector3.new(0, 0.1, 0))
note("Map.Start at course (%.1f, %.1f, %.1f)", spawnAt.X, spawnAt.Y, spawnAt.Z)

-- Finish: across the finale deck, from 1 stud past bay 4's exit to 1 stud short of the shell's end cap.
local finishZ1, finishZ2 = COURSE_END + 1, COURSE_END + FINALE - 1
local finishFloor = floorY(WIDTH / 2, (finishZ1 + finishZ2) / 2, 0)
marker("Finish", Vector3.new(WIDTH, 16, finishZ2 - finishZ1),
	Vector3.new(WIDTH / 2, finishFloor + 8, (finishZ1 + finishZ2) / 2))
note("Map.Finish: x 0..%d, z %d..%d (course), floor y %.1f", WIDTH, finishZ1, finishZ2, finishFloor)

-- LobbyPad: on the entrance deck near the right-hand fence, clear of the start, the bay 1 approach
-- (x 16, z -4) and runners standing 5 studs apart across the start.
local padX, padZ = WIDTH - 3.5, spawnAt.Z
local padFloor = floorY(padX, padZ, spawnAt.Y)
local pad = marker("LobbyPad", Vector3.new(5, 0.4, 5), Vector3.new(padX, padFloor + 0.2, padZ), {
	Transparency = 0, CanCollide = true, CanQuery = true, Material = Enum.Material.Neon,
	Color = Color3.fromRGB(45, 60, 50),
})
CollectionService:AddTag(pad, "LobbyTeleporter")
pad:SetAttribute("Enabled", false) -- Module.Start turns it on
note("Map.LobbyPad at course (%.1f, %.1f, %.1f), tagged LobbyTeleporter", padX, padFloor, padZ)

for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BaseScript") then
		note("removed script %s (maps hold no code)", d:GetFullName())
		d:Destroy()
	end
end

map:PivotTo(CFrame.new(0, 0, ORIGIN_Z))
map:SetAttribute("OriginZ", ORIGIN_Z)
map.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
local cf, size = map:GetBoundingBox()
note("Map moved +%d Z; bounds x %.0f..%.0f, y %.0f..%.0f, z %.0f..%.0f", ORIGIN_Z,
	cf.X - size.X / 2, cf.X + size.X / 2, cf.Y - size.Y / 2, cf.Y + size.Y / 2, cf.Z - size.Z / 2, cf.Z + size.Z / 2)

print("[prepare_obby_map] done. Now: right click Workspace.Map -> Save to File -> places/ObbyMap.rbxm, and close"
	.. " Place1 without saving.")
for _, line in ipairs(report) do
	print("  " .. line)
end
