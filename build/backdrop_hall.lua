-- build/backdrop_hall.lua -- the industrial hall around the course: floor, walls, windows,
-- roof + skylight, arched iron ribs, hanging gas lamps.
--
-- Run from the Studio command bar in EDIT mode:
--
--     loadstring(game:GetService("HttpService")
--         :GetAsync("http://127.0.0.1:8767/backdrop_hall.lua"))()
--
-- Idempotent: deletes and recreates Workspace.Backdrop.Hall and Workspace.Backdrop.Lamps.
-- Everything here is scenery -- Anchored, CanCollide/CanQuery/CanTouch false, CastShadow
-- false except the roof deck (whose shadow is what makes the hall darker than the course).
--
-- THE OVERSEER IS A CONSTRAINT. OverseerCam parks at y = 62 * zoom (zoom reaches 2.3, so up
-- to ~143) over the active bay looking down. Anything this script puts over the course --
-- the roof deck, the skylight, the arch segments -- is tagged "OverseerHide", and
-- OverseerCam's ghostWalls() hides tagged parts in x-ray. Lamps hang at y ~17-20, outside
-- the course footprint (x -16 and 48), so they never cross the overseer column.
--
-- LIGHT MUST NOT LEAK INTO THE DARK ROOM. PointLights without shadows shine through
-- geometry, so every lamp keeps Range <= 14 and sits >= 16 studs from the Bay 4 interior
-- (x 0..32): the light falls off before it crosses the wall line.
--
-- READABILITY. The skylight strip (x -4..36) runs the length of the hall over the course;
-- its glass has CastShadow = false, so the noon sun lands on the course floor while the
-- CastShadow = true roof deck keeps the rest of the hall in ambient gloom.

local CollectionService = game:GetService("CollectionService")

-- Config is read from SOURCE, not required -- Studio's Edit datamodel caches required
-- modules for the session. See build/fit_shell.lua.
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
local cell = configNumber("CellSize", 8)
local cols = configNumber("BayCols", 4)

local courseW = cell * cols                      -- 32
local shellStart = -entrance                     -- -10
local shellEnd = (keep - 1) * pitch + depth + finale  -- 124

-- Hall envelope. Fixed numbers, chosen around the course rather than derived from it, so
-- re-scoping the course does not silently resize the architecture.
local X1, X2 = -84, 116          -- inner wall faces
local Z1, Z2 = -64, 184
local FLOOR_TOP = -3             -- hall floor is 3 studs below the course platform
local WALL_TOP = 72             -- meets the roof deck: no sky slit above the walls
local ROOF_Y = 73.5              -- deck centre (72..75)
local SKY_X1, SKY_X2 = -4, 36    -- skylight strip straddling the course (x 0..32)
-- platform keep-out: nothing under the course footprint
local HX1, HX2 = -2, courseW + 2             -- -2..34
local HZ1, HZ2 = shellStart - 4, shellEnd + 4  -- -14..128

local COL = {
	floor = Color3.fromRGB(70, 63, 56),
	wall = Color3.fromRGB(76, 60, 46),
	patina = Color3.fromRGB(58, 86, 80),
	pilaster = Color3.fromRGB(46, 40, 36),
	pane = Color3.fromRGB(158, 126, 74),
	mullion = Color3.fromRGB(40, 36, 32),
	deck = Color3.fromRGB(36, 32, 30),
	glass = Color3.fromRGB(216, 186, 140),   -- heavily smoked glass: the sky reads amber-grey
	ribIron = Color3.fromRGB(32, 29, 27),
	brass = Color3.fromRGB(148, 108, 52),
	lampGlow = Color3.fromRGB(255, 196, 110),
	chain = Color3.fromRGB(50, 46, 42),
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
		for k, v in pairs(props) do
			p[k] = v
		end
	end
	p.Parent = parent
	made += 1
	return p
end

local backdrop = workspace:FindFirstChild("Backdrop")
if not backdrop then
	backdrop = Instance.new("Folder")
	backdrop.Name = "Backdrop"
	backdrop.Parent = workspace
end
for _, n in ipairs({"Hall", "Lamps"}) do
	local old = backdrop:FindFirstChild(n)
	if old then
		old:Destroy()
	end
end
local hall = Instance.new("Folder")
hall.Name = "Hall"
hall.Parent = backdrop
local lamps = Instance.new("Folder")
lamps.Name = "Lamps"
lamps.Parent = backdrop

----------------------------------------------------------------
-- Hall floor: four slabs around the platform keep-out, top at FLOOR_TOP.
----------------------------------------------------------------
local fy = FLOOR_TOP - 1.5
local function slab(name, x1, x2, z1, z2)
	mk(hall, name, Vector3.new(x2 - x1, 3, z2 - z1),
		Vector3.new((x1 + x2) / 2, fy, (z1 + z2) / 2), COL.floor, Enum.Material.Concrete)
end
slab("HallFloorLeft", X1, HX1, Z1, Z2)
slab("HallFloorRight", HX2, X2, Z1, Z2)
slab("HallFloorNear", HX1, HX2, Z1, HZ1)
slab("HallFloorFar", HX1, HX2, HZ2, Z2)

----------------------------------------------------------------
-- Walls, with a teal patina wainscot band.
----------------------------------------------------------------
local wy = (FLOOR_TOP + WALL_TOP) / 2    -- 31.5
local wh = WALL_TOP - FLOOR_TOP          -- 69
mk(hall, "HallWallLeft", Vector3.new(3, wh, (Z2 - Z1) + 6), Vector3.new(X1 - 1.5, wy, (Z1 + Z2) / 2), COL.wall, Enum.Material.CorrodedMetal)
mk(hall, "HallWallRight", Vector3.new(3, wh, (Z2 - Z1) + 6), Vector3.new(X2 + 1.5, wy, (Z1 + Z2) / 2), COL.wall, Enum.Material.CorrodedMetal)
mk(hall, "HallWallNear", Vector3.new((X2 - X1) + 6, wh, 3), Vector3.new((X1 + X2) / 2, wy, Z1 - 1.5), COL.wall, Enum.Material.CorrodedMetal)
mk(hall, "HallWallFar", Vector3.new((X2 - X1) + 6, wh, 3), Vector3.new((X1 + X2) / 2, wy, Z2 + 1.5), COL.wall, Enum.Material.CorrodedMetal)

mk(hall, "Wainscot", Vector3.new(0.7, 12, Z2 - Z1), Vector3.new(X1 + 0.35, FLOOR_TOP + 6, (Z1 + Z2) / 2), COL.patina, Enum.Material.Metal)
mk(hall, "Wainscot", Vector3.new(0.7, 12, Z2 - Z1), Vector3.new(X2 - 0.35, FLOOR_TOP + 6, (Z1 + Z2) / 2), COL.patina, Enum.Material.Metal)
mk(hall, "Wainscot", Vector3.new(X2 - X1, 12, 0.7), Vector3.new((X1 + X2) / 2, FLOOR_TOP + 6, Z1 + 0.35), COL.patina, Enum.Material.Metal)
mk(hall, "Wainscot", Vector3.new(X2 - X1, 12, 0.7), Vector3.new((X1 + X2) / 2, FLOOR_TOP + 6, Z2 - 0.35), COL.patina, Enum.Material.Metal)

task.wait()

----------------------------------------------------------------
-- Pilasters and arched windows. Long walls: 9 pilasters, 8 windows in the gaps.
-- Short walls: 7 pilasters, 6 windows. Window = amber pane + round arch + 2 mullions.
----------------------------------------------------------------
local function pilaster(x, z)
	mk(hall, "Pilaster", Vector3.new(4, wh, 4), Vector3.new(x, wy, z), COL.pilaster, Enum.Material.Metal)
end
local function window(wallAxis, wallCoord, along)
	-- wallAxis "x": wall is an x-wall (faces along X), window varies in Z, and vice versa.
	local paneCF, archCF, m1CF, m2CF
	if wallAxis == "x" then
		paneCF = CFrame.new(wallCoord, 49, along)
		archCF = CFrame.new(wallCoord, 56, along)
		m1CF = CFrame.new(wallCoord, 49, along - 2)
		m2CF = CFrame.new(wallCoord, 49, along + 2)
		mk(hall, "WindowPane", Vector3.new(0.6, 14, 12), paneCF, COL.pane, Enum.Material.Neon)
		mk(hall, "WindowArch", Vector3.new(0.6, 12, 12), archCF, COL.pane, Enum.Material.Neon, {Shape = Enum.PartType.Cylinder})
		mk(hall, "WindowBar", Vector3.new(0.9, 14, 0.7), m1CF, COL.mullion, Enum.Material.Metal)
		mk(hall, "WindowBar", Vector3.new(0.9, 14, 0.7), m2CF, COL.mullion, Enum.Material.Metal)
	else
		paneCF = CFrame.new(along, 49, wallCoord)
		archCF = CFrame.new(along, 56, wallCoord) * CFrame.Angles(0, math.rad(90), 0)
		m1CF = CFrame.new(along - 2, 49, wallCoord)
		m2CF = CFrame.new(along + 2, 49, wallCoord)
		mk(hall, "WindowPane", Vector3.new(12, 14, 0.6), paneCF, COL.pane, Enum.Material.Neon)
		mk(hall, "WindowArch", Vector3.new(0.6, 12, 12), archCF, COL.pane, Enum.Material.Neon, {Shape = Enum.PartType.Cylinder})
		mk(hall, "WindowBar", Vector3.new(0.7, 14, 0.9), m1CF, COL.mullion, Enum.Material.Metal)
		mk(hall, "WindowBar", Vector3.new(0.7, 14, 0.9), m2CF, COL.mullion, Enum.Material.Metal)
	end
end

local longPitch = (Z2 - Z1) / 8          -- 31
for k = 0, 8 do
	pilaster(X1, Z1 + k * longPitch)
	pilaster(X2, Z1 + k * longPitch)
	if k < 8 then
		window("x", X1, Z1 + k * longPitch + longPitch / 2)
		window("x", X2, Z1 + k * longPitch + longPitch / 2)
	end
end
local shortPitch = (X2 - X1) / 6         -- 33.3
for k = 0, 6 do
	pilaster(X1 + k * shortPitch, Z1)
	pilaster(X1 + k * shortPitch, Z2)
	if k < 6 then
		window("z", Z1, X1 + k * shortPitch + shortPitch / 2)
		window("z", Z2, X1 + k * shortPitch + shortPitch / 2)
	end
end

task.wait()

----------------------------------------------------------------
-- Roof deck (casts the hall's gloom) + skylight strip over the course (does not).
----------------------------------------------------------------
local deckL = mk(hall, "RoofDeckLeft", Vector3.new(SKY_X1 - (X1 - 3), 3, (Z2 - Z1) + 6),
	Vector3.new((X1 - 3 + SKY_X1) / 2, ROOF_Y, (Z1 + Z2) / 2), COL.deck, Enum.Material.CorrodedMetal, {CastShadow = true})
local deckR = mk(hall, "RoofDeckRight", Vector3.new((X2 + 3) - SKY_X2, 3, (Z2 - Z1) + 6),
	Vector3.new((SKY_X2 + X2 + 3) / 2, ROOF_Y, (Z1 + Z2) / 2), COL.deck, Enum.Material.CorrodedMetal, {CastShadow = true})
CollectionService:AddTag(deckL, "OverseerHide")
CollectionService:AddTag(deckR, "OverseerHide")

local skyZ1, skyZ2 = Z1 - 3, Z2 + 3
local nPanes = 10
local ribW = 1.6
local paneLen = ((skyZ2 - skyZ1) - (nPanes + 1) * ribW) / nPanes
local zc = skyZ1
for k = 0, nPanes do
	local rib = mk(hall, "SkylightRib", Vector3.new(SKY_X2 - SKY_X1, 1.2, ribW),
		Vector3.new((SKY_X1 + SKY_X2) / 2, ROOF_Y - 0.5, zc + ribW / 2), COL.mullion, Enum.Material.Metal)
	CollectionService:AddTag(rib, "OverseerHide")
	if k < nPanes then
		local pane = mk(hall, "SkylightPane", Vector3.new(SKY_X2 - SKY_X1, 0.4, paneLen),
			Vector3.new((SKY_X1 + SKY_X2) / 2, ROOF_Y - 0.4, zc + ribW + paneLen / 2),
			COL.glass, Enum.Material.Glass, {Transparency = 0.18})
		CollectionService:AddTag(pane, "OverseerHide")
	end
	zc = zc + ribW + paneLen
end

task.wait()

----------------------------------------------------------------
-- Arched iron ribs spanning the hall, like the reference image's roof arches.
-- Parabolic arc approximated with 6 segments; apex y=68 stays under the deck.
----------------------------------------------------------------
local ribZs = {-40, 0, 40, 80, 120, 160}
local arcXs = {-78, -47, -16, 16, 48, 79, 110}
local function arcY(x)
	local t = (x - 16) / 94
	return 68 - 18 * t * t
end
for _, z in ipairs(ribZs) do
	mk(hall, "RibLeg", Vector3.new(2.5, 53, 2.5), Vector3.new(-78, 23.5, z), COL.ribIron, Enum.Material.Metal)
	mk(hall, "RibLeg", Vector3.new(2.5, 53, 2.5), Vector3.new(110, 23.5, z), COL.ribIron, Enum.Material.Metal)
	for i = 1, #arcXs - 1 do
		local x1, x2 = arcXs[i], arcXs[i + 1]
		local y1, y2 = arcY(x1), arcY(x2)
		local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
		local ang = math.atan2(y2 - y1, x2 - x1)
		local seg = mk(hall, "RibArc", Vector3.new(len + 1, 1.8, 2.2),
			CFrame.new((x1 + x2) / 2, (y1 + y2) / 2, z) * CFrame.Angles(0, 0, ang),
			COL.ribIron, Enum.Material.Metal)
		CollectionService:AddTag(seg, "OverseerHide")
	end
end

task.wait()

----------------------------------------------------------------
-- Hanging gas lamps: two rows flanking the course (x -16 and 48), well clear of the
-- overseer column and of Bay 4. Chain from the roof, brass body, warm glass, PointLight.
----------------------------------------------------------------
-- A Cylinder part's axis is its X dimension, so every cylinder here is rotated 90° about Z
-- to stand it upright (the chain wants to hang, the body/glass/cap want to sit flat).
local upright = CFrame.Angles(0, 0, math.rad(90))
local lampZs = {-40, -10, 20, 50, 80, 110, 140, 170}
for _, x in ipairs({-16, 48}) do
	for _, z in ipairs(lampZs) do
		local m = Instance.new("Model")
		m.Name = "GasLamp"
		mk(m, "Chain", Vector3.new(52, 0.25, 0.25),
			CFrame.new(x, 46, z) * upright, COL.chain, Enum.Material.Metal,
			{Shape = Enum.PartType.Cylinder})
		mk(m, "Body", Vector3.new(1.8, 2.2, 2.2), CFrame.new(x, 19.3, z) * upright,
			COL.brass, Enum.Material.Metal, {Shape = Enum.PartType.Cylinder})
		local glass = mk(m, "Glass", Vector3.new(1.3, 1.4, 1.4), CFrame.new(x, 17.9, z) * upright,
			COL.lampGlow, Enum.Material.Neon, {Shape = Enum.PartType.Cylinder})
		mk(m, "Cap", Vector3.new(0.5, 1.0, 1.0), CFrame.new(x, 17.1, z) * upright,
			COL.brass, Enum.Material.Metal, {Shape = Enum.PartType.Cylinder})
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 180, 100)
		l.Brightness = 1.6
		l.Range = 14
		l.Shadows = false
		l.Parent = glass
		CollectionService:AddTag(glass, "BackdropFlicker")
		m.Parent = lamps
	end
end

local msg = string.format(
	"[backdrop_hall] built: %d parts (hall %d, lamps %d models), skylight x %d..%d, deck y %.1f",
	made, #hall:GetChildren(), #lamps:GetChildren(), SKY_X1, SKY_X2, ROOF_Y)
print(msg)
return msg
