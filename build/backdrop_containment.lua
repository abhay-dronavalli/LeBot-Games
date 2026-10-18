-- build/backdrop_containment.lua -- turn the visible box into an invisible one, and give the
-- course a floor at both ends plus a raised-platform skirt.
--
-- Run from the Studio command bar in EDIT mode:
--
--     loadstring(game:GetService("HttpService")
--         :GetAsync("http://127.0.0.1:8767/backdrop_containment.lua"))()
--
-- Idempotent: the Shell parts are FITTED in place (same names, never recreated, so
-- fit_shell.lua, scope_course.lua and OverseerCam keep finding them), and the parts this
-- script owns live in Workspace.Backdrop.Platform, which it deletes and rebuilds.
--
-- =========================  WHY THE CAMERA WAS A WALL  =========================
-- Roblox's default camera only "pops" (pulls in to avoid an obstruction) for parts its
-- Popper module considers occluders, and Popper's canOcclude() requires BOTH
-- Transparency < 0.25 AND CanCollide == true. The Shell was Transparency 0 / CanCollide
-- FALSE, which is the worst of both: no popping, so the camera slid straight INSIDE a solid
-- 48-stud wall and the near plane filled the screen with its backface.
--
-- Transparency 1 fixes it from the other direction -- an invisible part never occludes, so
-- the camera passes through it and shows the hall beyond, which is the whole point of
-- building a backdrop. CanCollide TRUE is then free: it is the containment layer, and it no
-- longer costs anything visually. CanQuery false keeps it out of raycasts (mouse picking,
-- the obstacle builders' probes) while leaving collision intact -- CanQuery and CanCollide
-- are independent.
--
-- THE SIDE WALLS MOVE IN. They sat at x = -7 and 39, seven studs beyond the bay floor edge,
-- with NOTHING under that gap -- step off the floor and you fell out of the world into an
-- invisible trench. Moved to the platform edge they become the fence line's collision, so
-- the player simply cannot leave the platform. Only X changes: fit_shell.lua and
-- scope_course.lua both rewrite Y and Z and preserve Position.X, so this survives a re-run
-- of either.

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

local W = cell * cols                              -- 32, course width
local Z1 = -entrance                               -- -10, platform starts
local Z2 = (keep - 1) * pitch + depth + finale     -- 124, platform ends
local HALL_TOP = -3                                -- hall floor top (backdrop_hall.lua)

-- Inner faces of the containment walls: one stud outside the floor edge, so a player can
-- stand on the very lip without being shoved by a wall they cannot see.
local INNER_L, INNER_R = -1, W + 1                 -- -1 and 33
local THICK = 2

local report = {}
local function note(...)
	table.insert(report, string.format(...))
end

----------------------------------------------------------------
-- 1. The Shell becomes an invisible collider.
----------------------------------------------------------------
local warehouse = workspace:WaitForChild("Warehouse")
local shell = warehouse:FindFirstChild("Shell")
if not shell then
	error("[containment] no Warehouse.Shell -- nothing to convert")
end

for _, p in ipairs(shell:GetChildren()) do
	if p:IsA("BasePart") then
		p.Transparency = 1
		p.CanCollide = true      -- the real containment, and the ONLY colliding backdrop layer
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		if p.Name == "WallLeft" then
			p.Position = Vector3.new(INNER_L - THICK / 2, p.Position.Y, p.Position.Z)
			p.Size = Vector3.new(THICK, p.Size.Y, p.Size.Z)
		elseif p.Name == "WallRight" then
			p.Position = Vector3.new(INNER_R + THICK / 2, p.Position.Y, p.Position.Z)
			p.Size = Vector3.new(THICK, p.Size.Y, p.Size.Z)
		end
		note("  %-13s invisible, collides, x=%.1f", p.Name, p.Position.X)
	end
end

----------------------------------------------------------------
-- 2. Platform: floors at both ends, and the skirt down to the hall floor.
----------------------------------------------------------------
local backdrop = workspace:FindFirstChild("Backdrop")
if not backdrop then
	backdrop = Instance.new("Folder")
	backdrop.Name = "Backdrop"
	backdrop.Parent = workspace
end
local old = backdrop:FindFirstChild("Platform")
if old then
	old:Destroy()
end
local platform = Instance.new("Folder")
platform.Name = "Platform"
platform.Parent = backdrop

local COL = {
	deck = Color3.fromRGB(62, 58, 54),
	skirt = Color3.fromRGB(48, 42, 38),
	trim = Color3.fromRGB(104, 78, 40),
}

local made = 0
-- NOTE: Platform is the one sub-folder of Backdrop that may collide -- these are surfaces
-- the player stands on, not scenery. Everything else under Backdrop is CanCollide false.
local function deck(name, x1, x2, z1, z2)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true          -- it is real ground: obstacle raycasts must find it
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(x2 - x1, 1, z2 - z1)
	p.Position = Vector3.new((x1 + x2) / 2, -0.5, (z1 + z2) / 2)
	p.Color = COL.deck
	p.Material = Enum.Material.DiamondPlate
	p.Parent = platform
	made += 1
	return p
end

-- The entrance buffer held nothing but the 6x6 spawn pad, and the finale buffer held
-- nothing at all: walking out of Bay 4's exit door dropped you into the void.
deck("EntranceFloor", 0, W, Z1, 0)
deck("FinaleFloor", 0, W, (keep - 1) * pitch + depth, Z2)

local function scenery(name, size, pos, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Position = pos
	p.Color = color
	p.Material = material
	p.Parent = platform
	made += 1
	return p
end

-- Skirt: closes the gap between the platform underside (y = -1) and the hall floor
-- (y = -3) so the course reads as a raised iron deck rather than a slab hanging in air.
-- It lives entirely BELOW y = 0, so it can never block a step.
local skirtH = 0 - HALL_TOP                 -- 3
local skirtY = HALL_TOP + skirtH / 2        -- -1.5
local lenZ = Z2 - Z1
scenery("SkirtLeft", Vector3.new(0.8, skirtH, lenZ), Vector3.new(-0.4, skirtY, (Z1 + Z2) / 2), COL.skirt, Enum.Material.Metal)
scenery("SkirtRight", Vector3.new(0.8, skirtH, lenZ), Vector3.new(W + 0.4, skirtY, (Z1 + Z2) / 2), COL.skirt, Enum.Material.Metal)
scenery("SkirtBack", Vector3.new(W + 1.6, skirtH, 0.8), Vector3.new(W / 2, skirtY, Z1 - 0.4), COL.skirt, Enum.Material.Metal)
scenery("SkirtFront", Vector3.new(W + 1.6, skirtH, 0.8), Vector3.new(W / 2, skirtY, Z2 + 0.4), COL.skirt, Enum.Material.Metal)

-- A brass nosing where the deck meets the skirt: catches the lamp light and draws the
-- platform edge, which is what sells "raised" from across the hall.
scenery("NosingLeft", Vector3.new(1.1, 0.35, lenZ), Vector3.new(-0.45, -0.15, (Z1 + Z2) / 2), COL.trim, Enum.Material.Metal)
scenery("NosingRight", Vector3.new(1.1, 0.35, lenZ), Vector3.new(W + 0.45, -0.15, (Z1 + Z2) / 2), COL.trim, Enum.Material.Metal)

note("  platform: entrance + finale floors, skirt and nosing to hall floor y=%.0f", HALL_TOP)

----------------------------------------------------------------
-- 3. The spawn. Faced DOWN the course, and sunk flush into the deck.
----------------------------------------------------------------
-- An identity-rotated part in Roblox looks along -Z. The course runs toward +Z, so the
-- default spawn had you facing backwards into the end cap, three studs from your nose, with
-- the camera parked inside it. This is the other half of "my camera is a wall".
local spawnPart = nil
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("SpawnLocation") then
		spawnPart = d
		break
	end
end
if spawnPart then
	local pos = Vector3.new(W / 2, -0.5, Z1 + 5)   -- top flush with the deck at y = 0
	spawnPart.CFrame = CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1))
	spawnPart.CanCollide = true
	spawnPart.Transparency = 0.35
	spawnPart.Color = COL.trim
	spawnPart.Material = Enum.Material.Metal
	note("  spawn at %s facing +Z (down the course), flush with the deck", tostring(pos))
else
	note("  NO SpawnLocation FOUND")
end

----------------------------------------------------------------
-- 4. Pallet racks: they were floating 3 studs over the new hall floor, half-buried in the
--    containment wall's old position. Stand them on the hall floor, out past the fence.
----------------------------------------------------------------
local racks = warehouse:FindFirstChild("PalletRacks")
local movedRacks = 0
if racks then
	for _, m in ipairs(racks:GetChildren()) do
		local ok, pivot = pcall(function()
			return m:GetPivot()
		end)
		if ok then
			local x = pivot.Position.X < W / 2 and -9 or (W + 9)
			m:PivotTo(CFrame.new(x, pivot.Position.Y + HALL_TOP, pivot.Position.Z))
			movedRacks += 1
		end
	end
end
note("  %d pallet rack(s) stood on the hall floor outside the fence line", movedRacks)

local msg = string.format("[backdrop_containment] %d platform parts\n%s", made, table.concat(report, "\n"))
print(msg)
return msg
