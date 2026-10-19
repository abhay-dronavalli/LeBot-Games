-- build/backdrop_props.lua -- everything that makes the hall a steampunk works:
-- fences along the course, pipe runs, machinery, laboratory areas, and per-bay dressing.
--
--     loadstring(game:GetService("HttpService")
--         :GetAsync("http://127.0.0.1:8767/backdrop_props.lua"))()
--
-- Idempotent: deletes and recreates Backdrop.Fences / .Pipes / .Machinery / .Labs /
-- .BayDressing. Run it as often as you like.
--
-- RULES BAKED IN HERE (see obby_planmds/environment.md):
--   * every part: Anchored, CanCollide/CanQuery/CanTouch false, CastShadow false.
--     The ONLY colliding layer in the whole backdrop is Warehouse.Shell (invisible) plus
--     Backdrop.Platform's decks. Fences are decoration -- the shell does the blocking.
--   * nothing opaque in the overseer's column: x -2..34, z -14..128, y 20..62. Anything
--     tall therefore lives outside x -2..34, or stays under y = 20, or is tagged
--     "OverseerHide" (OverseerCam.ghostWalls honours the tag).
--   * nothing under the course footprint -- the void shaft owns everything below bay 2.
--   * NO POINT LIGHTS near bay 4 (x 0..32, z 90..114). A PointLight has no shadows and
--     shines straight through the dark room's walls. Bay 4's dressing uses Neon only, which
--     is emissive but lights nothing.
--   * motion is client-side: parts are TAGGED here and animated by BackdropFx.client.lua.
--     Tags: BackdropSpin (gears, flywheels), BackdropFlicker (lamps, furnace glow),
--     BackdropSteam (an anchor that grows a ParticleEmitter on the client).

local CollectionService = game:GetService("CollectionService")

local function configNumber(name, fallback)
	local src = game.ReplicatedStorage:WaitForChild("Config").Source
	local v = src:match("[\r\n]Config%." .. name .. "%s*=%s*(%-?[%d%.]+)")
	return tonumber(v) or fallback
end

local pitch = configNumber("BayPitch", 30)
local depth = configNumber("BayDepth", 24)
local keep = configNumber("NumBays", 4)
local entrance = configNumber("EntranceBuffer", 10)
local finale = configNumber("FinaleBuffer", 10)
local W = configNumber("CellSize", 8) * configNumber("BayCols", 4)   -- 32

local Z1 = -entrance                                  -- -10
local Z2 = (keep - 1) * pitch + depth + finale        -- 124
local HALL = -3                                       -- hall floor top

local function bayZ(i) return (i - 1) * pitch end     -- bay i spans bayZ(i) .. +depth

local C = {
	iron    = Color3.fromRGB(42, 38, 35),
	brass   = Color3.fromRGB(150, 110, 52),
	copper  = Color3.fromRGB(138, 86, 50),
	patina  = Color3.fromRGB(62, 104, 96),
	steel   = Color3.fromRGB(88, 88, 94),
	rust    = Color3.fromRGB(104, 58, 34),
	fire    = Color3.fromRGB(255, 136, 40),
	ember   = Color3.fromRGB(255, 92, 26),
	glassy  = Color3.fromRGB(150, 220, 210),
	arc     = Color3.fromRGB(150, 220, 255),
	wood    = Color3.fromRGB(86, 62, 42),
}

local made = 0
local function mk(parent, name, size, cf, color, material, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = (typeof(cf) == "Vector3") and CFrame.new(cf) or cf
	p.Color = color
	p.Material = material
	if props then
		for k, v in pairs(props) do p[k] = v end
	end
	p.Parent = parent
	made += 1
	return p
end

-- A Cylinder's axis is its X, so these helpers spare us a rotation at every call site.
local UP = CFrame.Angles(0, 0, math.rad(90))
local function cylY(parent, name, dia, len, pos, color, mat, props)   -- standing up
	return mk(parent, name, Vector3.new(len, dia, dia), CFrame.new(pos) * UP, color, mat,
		props or {Shape = Enum.PartType.Cylinder})
end
local function cylX(parent, name, dia, len, pos, color, mat, props)   -- running along X
	return mk(parent, name, Vector3.new(len, dia, dia), CFrame.new(pos), color, mat,
		props or {Shape = Enum.PartType.Cylinder})
end
local function cylZ(parent, name, dia, len, pos, color, mat, props)   -- running along Z
	return mk(parent, name, Vector3.new(len, dia, dia),
		CFrame.new(pos) * CFrame.Angles(0, math.rad(90), 0), color, mat,
		props or {Shape = Enum.PartType.Cylinder})
end

local backdrop = workspace:FindFirstChild("Backdrop")
if not backdrop then
	backdrop = Instance.new("Folder"); backdrop.Name = "Backdrop"; backdrop.Parent = workspace
end
local FOLDERS = {"Fences", "Pipes", "Machinery", "Labs", "BayDressing"}
local F = {}
for _, n in ipairs(FOLDERS) do
	local old = backdrop:FindFirstChild(n)
	if old then old:Destroy() end
	local f = Instance.new("Folder"); f.Name = n; f.Parent = backdrop
	F[n] = f
end

----------------------------------------------------------------
-- 1. FENCES. The visible edge of the play space, see-through on purpose.
----------------------------------------------------------------
-- Posts and two rails rather than a bar every stud: it reads as a railing from the inside,
-- the hall stays visible through it, and it costs ~60 parts instead of ~400.
local FX_L, FX_R = -0.7, W + 0.7
local POST_H = 3.6
for _, x in ipairs({FX_L, FX_R}) do
	for z = Z1, Z2, 6 do
		mk(F.Fences, "FencePost", Vector3.new(0.35, POST_H, 0.35),
			Vector3.new(x, POST_H / 2, z), C.iron, Enum.Material.Metal)
	end
	-- one long rail each, merged: two parts instead of forty-four
	cylZ(F.Fences, "FenceRailTop", 0.3, Z2 - Z1, Vector3.new(x, POST_H, (Z1 + Z2) / 2), C.brass, Enum.Material.Metal)
	cylZ(F.Fences, "FenceRailMid", 0.22, Z2 - Z1, Vector3.new(x, POST_H * 0.55, (Z1 + Z2) / 2), C.brass, Enum.Material.Metal)
	-- a wire-mesh suggestion: one faint panel, not a lattice of parts
	mk(F.Fences, "FenceMesh", Vector3.new(0.06, POST_H - 0.5, Z2 - Z1),
		Vector3.new(x, (POST_H - 0.5) / 2, (Z1 + Z2) / 2), C.steel, Enum.Material.Metal,
		{Transparency = 0.82})
end
-- across both ends
for _, z in ipairs({Z1, Z2}) do
	for x = 0, W, 8 do
		mk(F.Fences, "FencePost", Vector3.new(0.35, POST_H, 0.35),
			Vector3.new(x, POST_H / 2, z), C.iron, Enum.Material.Metal)
	end
	cylX(F.Fences, "FenceRailTop", 0.3, W, Vector3.new(W / 2, POST_H, z), C.brass, Enum.Material.Metal)
	cylX(F.Fences, "FenceRailMid", 0.22, W, Vector3.new(W / 2, POST_H * 0.55, z), C.brass, Enum.Material.Metal)
end
task.wait()

----------------------------------------------------------------
-- 2. PIPES. Long merged runs on the hall walls and floor, with elbow balls at the joints.
----------------------------------------------------------------
local function elbow(parent, dia, pos, color)
	return mk(parent, "Elbow", Vector3.new(dia, dia, dia), pos, color, Enum.Material.Metal,
		{Shape = Enum.PartType.Ball})
end

-- Wall runs down both long sides of the hall, at four heights, in three gauges.
for _, side in ipairs({{-64, 1}, {80, -1}}) do
	local x, inward = side[1], side[2]
	for _, spec in ipairs({{6, 2.6, C.brass}, {14, 1.8, C.copper}, {23, 3.2, C.patina}, {34, 1.4, C.steel}}) do
		local y, dia, col = spec[1], spec[2], spec[3]
		cylZ(F.Pipes, "PipeRun", dia, 230, Vector3.new(x, y, 60), col, Enum.Material.Metal)
		-- risers tying the runs together
		for _, z in ipairs({-30, 40, 110, 170}) do
			cylY(F.Pipes, "PipeRiser", dia * 0.8, 16, Vector3.new(x + inward * 3, y - 8, z), col, Enum.Material.Metal)
			elbow(F.Pipes, dia * 1.25, Vector3.new(x, y, z), col)
		end
	end
	-- a fat low-level main running along the hall floor
	cylZ(F.Pipes, "PipeMain", 5.5, 236, Vector3.new(x + inward * 9, HALL + 3, 60), C.copper, Enum.Material.CorrodedMetal)
	for _, z in ipairs({-20, 30, 80, 140}) do
		mk(F.Pipes, "PipeCollar", Vector3.new(1.0, 6.6, 6.6),
			CFrame.new(x + inward * 9, HALL + 3, z) * CFrame.Angles(0, math.rad(90), 0),
			C.iron, Enum.Material.Metal, {Shape = Enum.PartType.Cylinder})
	end
	-- valve wheels, the signature steampunk silhouette
	for _, z in ipairs({-8, 52, 118, 162}) do
		local wheel = cylZ(F.Pipes, "ValveWheel", 3.4, 0.4, Vector3.new(x + inward * 9, HALL + 7.2, z), C.rust, Enum.Material.Metal)
		CollectionService:AddTag(wheel, "BackdropSpin")
		cylY(F.Pipes, "ValveStem", 0.5, 4, Vector3.new(x + inward * 9, HALL + 5.2, z), C.iron, Enum.Material.Metal)
	end
end
task.wait()

----------------------------------------------------------------
-- 3. MACHINERY. Boilers, furnaces, gear trains, flywheels, pistons, turbines.
----------------------------------------------------------------
-- One reusable cluster, mirrored and repeated down both sides at varying depth, so the hall
-- has parallax without hand-placing fifty machines.
local function machineCluster(x, z, flip, scale)
	local s = scale or 1
	local g = F.Machinery
	local dir = flip and -1 or 1

	-- boiler: a fat standing cylinder with bands and a firebox that glows
	cylY(g, "Boiler", 13 * s, 20 * s, Vector3.new(x, HALL + 10 * s, z), C.copper, Enum.Material.CorrodedMetal)
	for _, by in ipairs({4, 10, 16}) do
		cylY(g, "BoilerBand", 13.6 * s, 0.8 * s, Vector3.new(x, HALL + by * s, z), C.iron, Enum.Material.Metal)
	end
	local fire = mk(g, "Firebox", Vector3.new(5 * s, 4 * s, 1), Vector3.new(x + dir * 6.6 * s, HALL + 4 * s, z),
		C.fire, Enum.Material.Neon)
	CollectionService:AddTag(fire, "BackdropFlicker")
	-- boiler stack, kept well clear of the overseer column
	cylY(g, "Stack", 4 * s, 26 * s, Vector3.new(x, HALL + 32 * s, z), C.iron, Enum.Material.CorrodedMetal)
	local vent = mk(g, "SteamVent", Vector3.new(1, 1, 1), Vector3.new(x, HALL + 45 * s, z), C.steel,
		Enum.Material.Metal, {Transparency = 1})
	CollectionService:AddTag(vent, "BackdropSteam")

	-- gear train: three meshing wheels, all spinning
	for i, spec in ipairs({{0, 9, C.brass}, {7.4, 6, C.copper}, {12.6, 4, C.rust}}) do
		local gear = cylZ(g, "Gear", spec[2] * s, 1.1 * s,
			Vector3.new(x + dir * (14 + spec[1]) * s, HALL + 9 * s, z + 4), spec[3], Enum.Material.Metal)
		CollectionService:AddTag(gear, "BackdropSpin")
		gear:SetAttribute("SpinSpeed", (i % 2 == 0) and -0.9 or 0.55)
		-- teeth, suggested with a cross rather than modelled
		for t = 0, 3 do
			mk(g, "GearTooth", Vector3.new(0.8 * s, spec[2] * s * 1.12, 0.8 * s),
				CFrame.new(x + dir * (14 + spec[1]) * s, HALL + 9 * s, z + 4) * CFrame.Angles(0, 0, math.rad(t * 45)),
				spec[3], Enum.Material.Metal)
		end
	end

	-- flywheel on a shaft
	local fly = cylZ(g, "Flywheel", 14 * s, 1.4 * s, Vector3.new(x + dir * 24 * s, HALL + 11 * s, z - 7), C.iron, Enum.Material.Metal)
	CollectionService:AddTag(fly, "BackdropSpin")
	fly:SetAttribute("SpinSpeed", 0.35)
	cylZ(g, "Shaft", 1.3 * s, 22 * s, Vector3.new(x + dir * 24 * s, HALL + 11 * s, z + 2), C.steel, Enum.Material.Metal)

	-- piston pair
	for _, off in ipairs({-3.4, 3.4}) do
		cylY(g, "PistonBody", 3 * s, 9 * s, Vector3.new(x + dir * 31 * s, HALL + 5 * s, z + off), C.brass, Enum.Material.Metal)
		cylY(g, "PistonRod", 1.1 * s, 7 * s, Vector3.new(x + dir * 31 * s, HALL + 12 * s, z + off), C.steel, Enum.Material.Metal)
	end
	-- turbine housing
	cylZ(g, "Turbine", 10 * s, 6 * s, Vector3.new(x + dir * 40 * s, HALL + 7 * s, z + 10), C.patina, Enum.Material.CorrodedMetal)
	local blade = cylZ(g, "TurbineBlade", 8 * s, 0.5 * s, Vector3.new(x + dir * 40 * s, HALL + 7 * s, z + 13.2), C.steel, Enum.Material.Metal)
	CollectionService:AddTag(blade, "BackdropSpin")
	blade:SetAttribute("SpinSpeed", 2.2)
end

-- ORIGIN PLACEMENT IS LOAD-BEARING. Each cluster's arm (gears -> flywheel -> pistons ->
-- turbine) extends about 46 * scale studs INWARD from its origin. Place one at x = -44 and
-- its turbine lands at x = -4, which is on the player's walkway. Every origin below clears
-- the fence by 25+ studs at its own scale, and still sits inside the hall wall.
machineCluster(-74, -24, false, 1.0)
machineCluster(-76, 46, false, 1.15)
machineCluster(-72, 128, false, 0.95)
machineCluster(98, 4, true, 1.1)
machineCluster(100, 86, true, 1.0)
machineCluster(96, 156, true, 0.9)
task.wait()

----------------------------------------------------------------
-- 4. LABS. Glass tanks, tesla coils, vats, workbenches, scaffolding.
----------------------------------------------------------------
local function lab(x, z, flip)
	local g = F.Labs
	local dir = flip and -1 or 1
	-- glass tanks with something luminous inside
	for i = 0, 2 do
		local tz = z + i * 9
		cylY(g, "TankGlass", 6, 12, Vector3.new(x, HALL + 6, tz), C.glassy, Enum.Material.Glass, {Transparency = 0.55, Shape = Enum.PartType.Cylinder})
		cylY(g, "TankFluid", 5.2, 9, Vector3.new(x, HALL + 4.5, tz), C.patina, Enum.Material.Neon, {Transparency = 0.35, Shape = Enum.PartType.Cylinder})
		cylY(g, "TankCap", 6.6, 1, Vector3.new(x, HALL + 12.2, tz), C.brass, Enum.Material.Metal)
		cylY(g, "TankBase", 6.8, 1, Vector3.new(x, HALL + 0.5, tz), C.iron, Enum.Material.Metal)
	end
	-- tesla coils
	for _, off in ipairs({-9, 30}) do
		cylY(g, "CoilBase", 4.4, 2, Vector3.new(x + dir * 9, HALL + 1, z + off), C.iron, Enum.Material.Metal)
		cylY(g, "CoilColumn", 2.6, 11, Vector3.new(x + dir * 9, HALL + 7.5, z + off), C.copper, Enum.Material.Metal)
		local orb = mk(g, "CoilOrb", Vector3.new(4, 4, 4), Vector3.new(x + dir * 9, HALL + 15, z + off), C.arc,
			Enum.Material.Neon, {Shape = Enum.PartType.Ball})
		CollectionService:AddTag(orb, "BackdropFlicker")
		orb:SetAttribute("FlickerFast", true)
	end
	-- workbench + scaffolding
	mk(g, "BenchTop", Vector3.new(14, 0.4, 3), Vector3.new(x + dir * 17, HALL + 3.5, z + 12), C.wood, Enum.Material.Wood)
	for _, bx in ipairs({-6, 6}) do
		mk(g, "BenchLeg", Vector3.new(0.4, 3.5, 0.4), Vector3.new(x + dir * 17 + bx, HALL + 1.75, z + 12), C.iron, Enum.Material.Metal)
	end
	for lvl = 0, 2 do
		mk(g, "ScaffoldDeck", Vector3.new(16, 0.4, 5), Vector3.new(x + dir * 17, HALL + 8 + lvl * 7, z + 26), C.steel, Enum.Material.DiamondPlate)
		for _, px in ipairs({-7.5, 7.5}) do
			mk(g, "ScaffoldPost", Vector3.new(0.5, 7, 0.5), Vector3.new(x + dir * 17 + px, HALL + 4.5 + lvl * 7, z + 26), C.steel, Enum.Material.Metal)
		end
	end
end
lab(-62, 70, false)
lab(78, 40, true)
task.wait()

----------------------------------------------------------------
-- 5. PER-BAY DRESSING, outside the obstacle folders and outside the play space.
----------------------------------------------------------------
local D = F.BayDressing

-- ---- Bay 1, the saw chamber: riveted sawmill plating, drive gear, steam on top. No roof.
do
	local z0, zc = bayZ(1), bayZ(1) + depth / 2
	for _, side in ipairs({{-1.4, 1}, {W + 1.4, -1}}) do
		local x, dir = side[1], side[2]
		mk(D, "SawPlating", Vector3.new(1.4, 16, depth), Vector3.new(x, 8, zc), C.rust, Enum.Material.CorrodedMetal)
		-- rivet bands
		for _, y in ipairs({3, 8, 13}) do
			cylZ(D, "RivetBand", 0.5, depth, Vector3.new(x - dir * 0.8, y, zc), C.iron, Enum.Material.Metal)
		end
		-- the drive that "powers" the blades: big flywheel + belt running into the wall
		local fw = cylZ(D, "SawFlywheel", 11, 1.2, Vector3.new(x - dir * 6, 8, z0 + 6), C.iron, Enum.Material.Metal)
		CollectionService:AddTag(fw, "BackdropSpin")
		fw:SetAttribute("SpinSpeed", 1.6)
		cylZ(D, "SawShaft", 1.2, 14, Vector3.new(x - dir * 6, 8, z0 + 13), C.steel, Enum.Material.Metal)
		mk(D, "SawBelt", Vector3.new(0.3, 10, 1.2), Vector3.new(x - dir * 3, 8, z0 + 6), C.iron, Enum.Material.Fabric)
		-- steam vents on the chamber top (y 17, below the overseer column floor of 20)
		for _, z in ipairs({z0 + 5, z0 + 19}) do
			cylY(D, "VentPipe", 1.6, 4, Vector3.new(x - dir * 1.2, 17, z), C.brass, Enum.Material.Metal)
			local v = mk(D, "SteamVent", Vector3.new(1, 1, 1), Vector3.new(x - dir * 1.2, 19.2, z), C.steel,
				Enum.Material.Metal, {Transparency = 1})
			CollectionService:AddTag(v, "BackdropSteam")
		end
	end
end

-- ---- Bay 2, the void: pipes and chains down into the pit, furnace glow from below.
do
	local z0, zc = bayZ(2), bayZ(2) + depth / 2
	for _, side in ipairs({{-2.4, 1}, {W + 2.4, -1}}) do
		local x, dir = side[1], side[2]
		-- pipes bending down over the lip
		for _, z in ipairs({z0 + 5, z0 + 12}) do
			cylY(D, "PitPipe", 2.2, 22, Vector3.new(x, -11, z), C.copper, Enum.Material.CorrodedMetal)
			elbow(D, 2.8, Vector3.new(x, 0.2, z), C.copper)
			cylX(D, "PitSpur", 2.0, 5, Vector3.new(x - dir * 2.5, 0.2, z), C.copper, Enum.Material.CorrodedMetal)
		end
		-- chains hanging into the dark
		for _, z in ipairs({z0 + 8, z0 + 16, z0 + 20}) do
			cylY(D, "PitChain", 0.3, 30, Vector3.new(x - dir * 0.8, -14, z), C.iron, Enum.Material.Metal)
		end
	end
	-- furnace glow rising out of the shaft. Neon only -- a PointLight here would wash the
	-- bay floor and make the drop look safe.
	for i = 0, 3 do
		local glow = mk(D, "PitGlow", Vector3.new(W - 6, 0.6, 5), Vector3.new(W / 2, -20 - i * 6, zc - 2),
			i < 2 and C.ember or C.fire, Enum.Material.Neon, {Transparency = 0.45 + i * 0.12})
		CollectionService:AddTag(glow, "BackdropFlicker")
	end
	local emb = mk(D, "EmberSource", Vector3.new(1, 1, 1), Vector3.new(W / 2, -16, zc), C.ember,
		Enum.Material.Neon, {Transparency = 1})
	CollectionService:AddTag(emb, "BackdropEmber")
end

-- ---- Bay 3, laser walk: brass emitter posts on the fence line at the real beam heights.
do
	local z0 = bayZ(3)
	-- Config'd beam heights. Cosmetic only: the real beams are built by HazardManager.
	local BEAMS = {1.6, 4.4, 7.2}
	for _, side in ipairs({{-1.3, 1}, {W + 1.3, -1}}) do
		local x, dir = side[1], side[2]
		for _, z in ipairs({z0 + 4, z0 + 12, z0 + 20}) do
			cylY(D, "EmitterColumn", 1.5, 9, Vector3.new(x, 4.5, z), C.brass, Enum.Material.Metal)
			for _, y in ipairs(BEAMS) do
				cylX(D, "EmitterNozzle", 0.9, 2.2, Vector3.new(x - dir * 1.1, y, z), C.iron, Enum.Material.Metal)
				mk(D, "EmitterLens", Vector3.new(0.5, 0.5, 0.5), Vector3.new(x - dir * 2.1, y, z),
					Color3.fromRGB(255, 60, 60), Enum.Material.Neon, {Shape = Enum.PartType.Ball})
			end
		end
		-- tesla coils flanking, as the supposed power source
		for _, z in ipairs({z0 + 1, z0 + 23}) do
			cylY(D, "CoilColumn", 2.2, 10, Vector3.new(x - dir * 3.5, 5, z), C.copper, Enum.Material.Metal)
			local orb = mk(D, "CoilOrb", Vector3.new(3, 3, 3), Vector3.new(x - dir * 3.5, 11, z), C.arc,
				Enum.Material.Neon, {Shape = Enum.PartType.Ball})
			CollectionService:AddTag(orb, "BackdropFlicker")
			orb:SetAttribute("FlickerFast", true)
		end
	end
end

-- ---- Bay 4, the dark room: boiler-house plating, pipes into the walls, a venting stack.
-- NEON ONLY. Nothing here may emit light -- see the header.
do
	local z0, zc = bayZ(4), bayZ(4) + depth / 2
	for _, side in ipairs({{-1.4, 1}, {W + 1.4, -1}}) do
		local x, dir = side[1], side[2]
		mk(D, "VaultPlating", Vector3.new(1.4, 14, depth), Vector3.new(x, 7, zc), C.iron, Enum.Material.DiamondPlate)
		for _, y in ipairs({3.5, 10.5}) do
			cylZ(D, "RivetBand", 0.55, depth, Vector3.new(x - dir * 0.8, y, zc), C.steel, Enum.Material.Metal)
		end
		-- pipes entering the wall
		for _, z in ipairs({z0 + 6, z0 + 17}) do
			cylX(D, "VaultPipe", 2.4, 9, Vector3.new(x - dir * 5, 6, z), C.copper, Enum.Material.CorrodedMetal)
			elbow(D, 3, Vector3.new(x - dir * 9.5, 6, z), C.copper)
			cylY(D, "VaultRiser", 2.4, 14, Vector3.new(x - dir * 9.5, 13, z), C.copper, Enum.Material.CorrodedMetal)
		end
		-- venting stack, parked outside the overseer column (x -2..34)
		cylY(D, "VentStack", 5, 24, Vector3.new(x - dir * 14, 12, zc), C.iron, Enum.Material.CorrodedMetal)
		local v = mk(D, "SteamVent", Vector3.new(1, 1, 1), Vector3.new(x - dir * 14, 24.5, zc), C.steel,
			Enum.Material.Metal, {Transparency = 1})
		CollectionService:AddTag(v, "BackdropSteam")
	end
	-- the finale: a furnace gate past the exit door, so the course ends at the machine's mouth
	-- Sat at the very end, against the end cap, so it is something you walk UP TO rather
	-- than through. Its columns are outside the floor edge for the same reason: a column at
	-- x = 7 is a solid-looking post standing in the middle of the only path out.
	local fz = Z2 - 0.8
	mk(D, "FurnaceFrame", Vector3.new(W + 14, 19, 1.6), Vector3.new(W / 2, 9.5, fz), C.iron, Enum.Material.CorrodedMetal)
	local mouth = mk(D, "FurnaceMouth", Vector3.new(15, 11, 0.6), Vector3.new(W / 2, 5.6, fz - 1.1), C.fire, Enum.Material.Neon)
	CollectionService:AddTag(mouth, "BackdropFlicker")
	for _, bx in ipairs({-4, W + 4}) do
		cylY(D, "FurnaceColumn", 3.4, 22, Vector3.new(bx, 11, fz - 1.4), C.brass, Enum.Material.Metal)
	end
	local fe = mk(D, "FurnaceEmber", Vector3.new(1, 1, 1), Vector3.new(W / 2, 3, fz - 2),
		C.ember, Enum.Material.Neon, {Transparency = 1})
	CollectionService:AddTag(fe, "BackdropEmber")
end

-- ---- Entrance: a boiler-room airlock gate you walk out of.
do
	mk(D, "GateLintel", Vector3.new(W + 10, 3, 2.2), Vector3.new(W / 2, 13, Z1), C.iron, Enum.Material.CorrodedMetal)
	for _, bx in ipairs({-2.5, W + 2.5}) do
		mk(D, "GateJamb", Vector3.new(4, 14, 2.2), Vector3.new(bx, 7, Z1), C.iron, Enum.Material.CorrodedMetal)
		cylY(D, "GateBolt", 1.2, 13, Vector3.new(bx, 7, Z1 - 1.4), C.brass, Enum.Material.Metal)
	end
	for i = 0, 3 do
		cylX(D, "GatePipe", 1.5, W + 12, Vector3.new(W / 2, 14.6 + i * 1.5, Z1 - 0.4), C.copper, Enum.Material.Metal)
	end
	local lamp = mk(D, "GateLamp", Vector3.new(2.4, 1.2, 0.8), Vector3.new(W / 2, 12.4, Z1 - 1.3), C.fire, Enum.Material.Neon)
	CollectionService:AddTag(lamp, "BackdropFlicker")
end
task.wait()

----------------------------------------------------------------
-- 6. CATWALKS: restyled in place. Material and colour only -- never resized, because the
--    bays' approach geometry is measured against them.
----------------------------------------------------------------
local catwalks = workspace.Warehouse:FindFirstChild("Catwalks")
local restyled = 0
for _, m in ipairs(catwalks and catwalks:GetChildren() or {}) do
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") then
			if p.Name == "Floor" then
				p.Material = Enum.Material.DiamondPlate
				p.Color = C.iron
			else
				p.Material = Enum.Material.Metal
				p.Color = C.brass
			end
			restyled += 1
		end
	end
end

local counts = {}
for _, n in ipairs(FOLDERS) do
	counts[#counts + 1] = string.format("%s=%d", n, #F[n]:GetChildren())
end
local msg = string.format("[backdrop_props] %d parts (%s); %d catwalk parts restyled",
	made, table.concat(counts, " "), restyled)
print(msg)
return msg
