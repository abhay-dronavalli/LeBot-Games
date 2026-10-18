--!strict
-- The volcanic arena: floor, lava, cliffs, cover, background, lighting and impact marks.
--
-- THE FLOOR IS THE PRINTED SHEET. The style guide (section 5) asks for the floor to be the outline
-- the real tip can reach, logged by driving the arm around with the jaw near the table. Nobody has
-- logged that yet, and until they do the sheet is the honest stand-in rather than a guess: it is
-- the actual work surface in front of the arm, its size arrives in `hello.space.sheet` instead of
-- being written down, and every block the game knows about sits on it.
--
-- The pedestal goes at `hello.space.arm_base_mm`, which is off the *top* edge of the sheet - the
-- arm really does stand behind the paper. So the guide's layout falls out of the real geometry for
-- free: the dragon is at the back against the cliff, and the floor fans out in front of it. No
-- round arena, so no safe spot behind the dragon where the shoulder pan cannot turn.
--
-- When the reach outline is finally logged, it replaces `floorFromSheet` and nothing else in the
-- mode changes. This is the only file that knows the floor's shape.
--
-- THE FLOOR IS ABOVE THE REAL TABLE. The arena floor sits at ARENA_FLOOR_MM above the paper, so
-- the dragon's head hits the in-game floor while the real jaw is still safely in the air. The
-- operator must never have to bang the arm into the table to land a slam.
--
--   local arena = Arena.new(workspace)
--   Bridge.onHello(function(h) arena:build(h.space) end)

local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Mapping = require(script.Parent.Parent.Mapping)

local Arena = {}
Arena.__index = Arena

local C = Theme.Color

local function part(parent: Instance, name: string, color: Color3, material: Enum.Material,
	size: Vector3, cf: CFrame, collide: boolean?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = collide ~= false
	p.CanQuery = collide ~= false
	p.CanTouch = false
	p.Material = material
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function Arena.new(parent: Instance)
	local self = setmetatable({}, Arena)
	self.model = Instance.new("Model")
	self.model.Name = "Arena"
	self.model.Parent = parent
	self.marks = {} :: { BasePart }      -- newest last; the oldest is removed past the budget
	self.lights = 0
	self.floorTopY = 0
	self.bounds = nil :: any
	self.built = false
	return self
end

-- Where the arena floor's *surface* is, in studs. Attack detection compares the real tip against
-- ARENA_FLOOR_MM in millimetres, but the visuals need the same plane in world units, and taking it
-- from Mapping is what keeps the two from drifting apart when the scale is retuned.
function Arena.floorY(self): number
	return Mapping.point({ x = 0, y = 0, z = ArenaConfig.ARENA_FLOOR_MM }).Y
end

-- The sheet rectangle, grown by the margin, with the back edge pushed out far enough to stand the
-- pedestal on. Returns millimetre bounds in the sheet frame.
function Arena.floorFromSheet(self, space: any): any
	local w = (space and space.sheet and space.sheet.w_mm) or 279.4
	local h = (space and space.sheet and space.sheet.h_mm) or 215.9
	local base = (space and space.arm_base_mm) or { w / 2, -44.5 }
	local m = ArenaConfig.ARENA_MARGIN_MM

	-- Capped at 1. Shrinking the floor is safe - a smaller floor is more reachable - but growing it
	-- past the sheet would hand players ground the arm cannot cover, which is the one thing the
	-- style guide says must never happen.
	local depthScale = math.clamp(ArenaConfig.ARENA_SCALE or 1, 0.15, 1)
	local widthScale = math.clamp(ArenaConfig.ARENA_WIDTH_SCALE or 1, 0.15, 1)

	-- The arm base is at a negative y (behind the top edge of the paper), so the floor has to reach
	-- back past it for the pedestal to stand on something. That back edge is the anchor: the floor
	-- shrinks *toward the dragon*, keeping it against the cliff while the far edge comes closer,
	-- rather than shrinking toward the middle and leaving the pedestal floating in the lava.
	local y0 = math.min(-m, base[2] - m)
	local y1 = y0 + ((h + m) - y0) * depthScale

	-- Across the sheet there is no anchor to respect, so this shrinks about the centre.
	local cx = w / 2
	local halfW = (w / 2 + m) * widthScale

	return {
		x0 = cx - halfW,
		x1 = cx + halfW,
		y0 = y0,
		y1 = y1,
		baseX = base[1],
		baseY = base[2],
		sheetW = w,
		sheetH = h,
	}
end

function Arena.build(self, space: any)
	if self.built then
		return
	end
	self.built = true
	local b = self:floorFromSheet(space)
	self.bounds = b
	-- Platform heights are in units of the player's jump, which is in turn scaled to the real cube
	-- size from `hello`. Hardcoding either one puts a ledge out of reach the moment the scale or
	-- the block size changes.
	self.cubeMm = (space and space.cube_mm) or 48
	local s = Mapping.STUDS_PER_MM
	local floorY = self:floorY()
	self.floorTopY = floorY

	local function world(xMm: number, yMm: number, yStuds: number): Vector3
		return Mapping.ORIGIN + Vector3.new(xMm * s, yStuds, yMm * s)
	end

	local wx = (b.x1 - b.x0) * s
	local wz = (b.y1 - b.y0) * s
	local cx = (b.x0 + b.x1) / 2
	local cz = (b.y0 + b.y1) / 2

	-- Floor. Dark obsidian, mostly flat. Orange stays off it except at the lava edge and on
	-- temporary impact glow, so fire and shockwaves have something dark to stand out against.
	local floor = part(self.model, "Floor", C.Obsidian, Enum.Material.Basalt,
		Vector3.new(wx, 4, wz), CFrame.new(world(cx, cz, floorY - 2)))
	self.floor = floor

	-- A few thin cracks, Neon at high transparency. Few on purpose: a floor lit all over competes
	-- with the fire.
	for k = 1, 6 do
		local fx = b.x0 + (b.x1 - b.x0) * (k / 7)
		local crack = part(self.model, "Crack" .. k, C.Ember, Enum.Material.Neon,
			Vector3.new(0.6, 0.2, wz * (0.3 + 0.4 * ((k * 7) % 5) / 5)),
			CFrame.new(world(fx, cz, floorY + 0.02)) * CFrame.Angles(0, math.rad((k % 3) * 12 - 12), 0),
			false)
		crack.Transparency = 0.4
	end

	self:buildLava(b, s, floorY)
	self:buildCliffs(b, s, floorY)
	self:buildCover(b, s, floorY)
	self:buildBackground(b, s, floorY)
	self:applyLighting()
end

-- Lava surrounds the reachable floor: everything the dragon cannot hit must be fatal, or players
-- find a corner to stand in and the round stops being a dodge.
function Arena.buildLava(self, b: any, s: number, floorY: number)
	local lw = ArenaConfig.LAVA_WIDTH_MM
	local sides = {
		{ x0 = b.x0 - lw, x1 = b.x1 + lw, y0 = b.y0 - lw, y1 = b.y0 },
		{ x0 = b.x0 - lw, x1 = b.x1 + lw, y0 = b.y1,      y1 = b.y1 + lw },
		{ x0 = b.x0 - lw, x1 = b.x0,      y0 = b.y0,      y1 = b.y1 },
		{ x0 = b.x1,      x1 = b.x1 + lw, y0 = b.y0,      y1 = b.y1 },
	}
	for i, q in sides do
		local size = Vector3.new((q.x1 - q.x0) * s, 3, (q.y1 - q.y0) * s)
		local at = Mapping.ORIGIN + Vector3.new((q.x0 + q.x1) / 2 * s, floorY - 2.4, (q.y0 + q.y1) / 2 * s)
		part(self.model, "Lava" .. i, C.Lava, Enum.Material.CrackedLava, size, CFrame.new(at))
		-- A Neon strip along the inner edge does the glow. Neon plus Bloom is far cheaper than a
		-- light, which matters because Future lighting makes lights expensive.
		local glow = part(self.model, "LavaGlow" .. i, C.LavaHot, Enum.Material.Neon,
			Vector3.new(size.X, 0.4, size.Z),
			CFrame.new(at + Vector3.new(0, 1.6, 0)), false)
		glow.Transparency = 0.3
	end

	-- At most MAX_ENV_POINT_LIGHTS in the lava. Everything else glows with Neon and Bloom.
	local n = math.min(ArenaConfig.MAX_ENV_POINT_LIGHTS, 8)
	for k = 1, n do
		local a = (k / n) * math.pi * 2
		local host = part(self.model, "LavaLight" .. k, C.Lava, Enum.Material.Neon,
			Vector3.new(1, 1, 1),
			CFrame.new(Mapping.ORIGIN + Vector3.new(
				((b.x0 + b.x1) / 2 + math.cos(a) * (b.x1 - b.x0) * 0.62) * s,
				floorY + 1,
				((b.y0 + b.y1) / 2 + math.sin(a) * (b.y1 - b.y0) * 0.62) * s)), false)
		host.Transparency = 1
		local l = Instance.new("PointLight")
		l.Color = C.Lava
		l.Range = 20
		l.Brightness = 2
		l.Parent = host
		self.lights += 1
	end
end

-- The back wall the pedestal stands against: the dragon's lair. Side walls keep the camera from
-- looking out into nothing.
function Arena.buildCliffs(self, b: any, s: number, floorY: number)
	local h = ArenaConfig.CLIFF_HEIGHT
	local lw = ArenaConfig.LAVA_WIDTH_MM
	local back = part(self.model, "BackCliff", C.Basalt, Enum.Material.Rock,
		Vector3.new((b.x1 - b.x0 + lw * 2) * s, h, 10),
		CFrame.new(Mapping.ORIGIN + Vector3.new((b.x0 + b.x1) / 2 * s, floorY + h / 2, (b.y0 - 5) * s)))
	part(self.model, "BackCliffEdge", C.BasaltEdge, Enum.Material.Slate,
		Vector3.new(back.Size.X, 1.2, 11),
		CFrame.new(back.Position + Vector3.new(0, h / 2, 0)), false)
end

-- Cover and height. Rocks block fire (the cone raycasts), and the low platforms give somewhere to
-- jump. Everything is inside the floor, so there is nowhere the dragon cannot reach.
function Arena.buildCover(self, b: any, s: number, floorY: number)
	local jump = Mapping.jumpHeight(self.cubeMm or 48)
	local spots = {
		{ fx = 0.22, fy = 0.34, r = 9,  plat = false },
		{ fx = 0.76, fy = 0.30, r = 11, plat = false },
		{ fx = 0.50, fy = 0.66, r = 8,  plat = false },
		{ fx = 0.14, fy = 0.72, r = 7,  plat = true,  lift = 0.55 },
		{ fx = 0.86, fy = 0.70, r = 7,  plat = true,  lift = 0.55 },
		{ fx = 0.34, fy = 0.52, r = 6,  plat = true,  lift = 1.15 },
		{ fx = 0.66, fy = 0.50, r = 6,  plat = true,  lift = 1.15 },
	}
	for i, sp in spots do
		local xMm = b.x0 + (b.x1 - b.x0) * sp.fx
		local yMm = b.y0 + (b.y1 - b.y0) * sp.fy
		-- Platform heights are given in units of the arena's JumpHeight, so retuning the scale
		-- retunes the climb instead of silently putting a ledge out of reach.
		local y = floorY + (sp.plat and jump * (sp.lift or 0.55) or sp.r * 0.4)
		local at = Mapping.ORIGIN + Vector3.new(xMm * s, y, yMm * s)
		if sp.plat then
			part(self.model, "Platform" .. i, C.Basalt, Enum.Material.Slate,
				Vector3.new(sp.r * 2.6, 2.2, sp.r * 2.6), CFrame.new(at))
			part(self.model, "PlatformEdge" .. i, C.BasaltEdge, Enum.Material.Slate,
				Vector3.new(sp.r * 2.7, 0.5, sp.r * 2.7),
				CFrame.new(at + Vector3.new(0, 1.3, 0)), false)
		else
			local rock = part(self.model, "Rock" .. i, C.Basalt, Enum.Material.Rock,
				Vector3.new(sp.r * 1.7, sp.r * 1.5, sp.r * 1.9),
				CFrame.new(at) * CFrame.Angles(0, i * 0.7, 0.06))
			part(self.model, "RockEdge" .. i, C.BasaltEdge, Enum.Material.Slate,
				Vector3.new(sp.r * 1.4, 0.5, sp.r * 1.6),
				rock.CFrame * CFrame.new(0, sp.r * 0.75, 0), false)
		end
	end
end

-- Tall spires and lavafalls outside the play area, dark against the sky. They frame the dragon,
-- and must never be brighter than it: a background that out-glows the dragon flattens the scene.
function Arena.buildBackground(self, b: any, s: number, floorY: number)
	local lw = ArenaConfig.LAVA_WIDTH_MM
	for k = 1, 10 do
		local a = (k / 10) * math.pi * 2 + 0.3
		local dist = (b.x1 - b.x0) * 0.7 + lw
		local xMm = (b.x0 + b.x1) / 2 + math.cos(a) * dist
		local yMm = (b.y0 + b.y1) / 2 + math.sin(a) * dist * 0.8
		local h = 70 + (k % 4) * 45
		local spire = part(self.model, "Spire" .. k, C.Basalt, Enum.Material.Rock,
			Vector3.new(14 + (k % 3) * 6, h, 14 + (k % 2) * 7),
			CFrame.new(Mapping.ORIGIN + Vector3.new(xMm * s, floorY + h / 2 - 6, yMm * s))
				* CFrame.Angles(0, a, 0),
			false)
		if k % 3 == 0 then
			local fall = part(self.model, "Lavafall" .. k, C.Lava, Enum.Material.Neon,
				Vector3.new(3, h * 0.7, 1.5),
				spire.CFrame * CFrame.new(spire.Size.X / 2 + 0.6, -h * 0.1, 0), false)
			fall.Transparency = 0.25
		end
	end
end

function Arena.applyLighting(self)
	-- Technology is set in the Studio Properties panel, not from a script: Future needs a restart
	-- of the lighting pass to take effect properly and scripting it mid-session gives a different
	-- result than shipping it. See the arena README.
	local L = ArenaConfig.LIGHTING
	Lighting.ClockTime = 0
	Lighting.Brightness = L.Brightness
	Lighting.ExposureCompensation = L.ExposureCompensation
	Lighting.Ambient = Theme.Lighting.Ambient
	Lighting.OutdoorAmbient = Theme.Lighting.OutdoorAmbient
	Lighting.EnvironmentDiffuseScale = L.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = L.EnvironmentSpecularScale
	Lighting.GlobalShadows = true

	local function ensure(class: string, name: string): Instance
		local inst = Lighting:FindFirstChild(name)
		if not inst then
			inst = Instance.new(class)
			inst.Name = name
			inst.Parent = Lighting
		end
		return inst
	end

	local atm = ensure("Atmosphere", "ArenaAtmosphere") :: Atmosphere
	atm.Density = L.AtmosphereDensity
	atm.Offset = 0.1
	atm.Color = Theme.Lighting.AtmosphereTint
	atm.Decay = Theme.Lighting.AtmosphereDecay
	atm.Glare = L.AtmosphereGlare
	atm.Haze = L.AtmosphereHaze

	-- Neon has to actually glow, or the whole brightness order collapses: the hazards stop out-
	-- ranking the dragon and the scene reads flat.
	local bloom = ensure("BloomEffect", "ArenaBloom") :: BloomEffect
	bloom.Intensity = L.BloomIntensity
	bloom.Size = 28
	bloom.Threshold = L.BloomThreshold

	local cc = ensure("ColorCorrectionEffect", "ArenaGrade") :: ColorCorrectionEffect
	cc.Contrast = L.Contrast
	cc.Saturation = L.Saturation
	cc.TintColor = Theme.Lighting.GradeTint

	local sky = ensure("Sky", "ArenaSky") :: Sky
	sky.CelestialBodiesShown = false
	sky.StarCount = 0

	self:buildEmbers()
end

-- Ambient embers drifting up over the arena. One emitter, low rate: this is atmosphere, and it has
-- to leave room in the ~400-particle budget for the fire and the slams.
function Arena.buildEmbers(self)
	if not self.bounds then
		return
	end
	local b = self.bounds
	local s = Mapping.STUDS_PER_MM
	local host = part(self.model, "EmberSource", C.Ember, Enum.Material.Neon, Vector3.new(1, 1, 1),
		CFrame.new(Mapping.ORIGIN + Vector3.new((b.x0 + b.x1) / 2 * s, self.floorTopY + 30,
			(b.y0 + b.y1) / 2 * s)), false)
	host.Transparency = 1

	local e = Instance.new("ParticleEmitter")
	e.Name = "Embers"
	e.Color = ColorSequence.new(C.Ember, C.LavaHot)
	e.Size = NumberSequence.new(0.4)
	e.Lifetime = NumberRange.new(4, 7)
	e.Rate = 6
	e.Speed = NumberRange.new(2, 5)
	e.SpreadAngle = Vector2.new(25, 25)
	e.LightEmission = 1
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.EmissionDirection = Enum.NormalId.Top
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	-- Sized before the emitter is parented: the Box shape emits from the host's volume, so a host
	-- still 1x1x1 at that moment drips embers from a single point above the middle of the arena.
	host.Size = Vector3.new((b.x1 - b.x0) * s, 2, (b.y1 - b.y0) * s)
	e.Parent = host
end

-- ---------------------------------------------------------------------------------------------
-- Impact marks. Craters and scorch patches are left *after* a hit, which hard rule 1 allows -
-- they are history, not a prediction of where the next strike lands.
-- ---------------------------------------------------------------------------------------------

function Arena.trimMarks(self)
	while #self.marks > ArenaConfig.MAX_IMPACT_MARKS do
		local oldest = table.remove(self.marks, 1)
		if oldest then
			oldest:Destroy()
		end
	end
end

-- A crater: an ObsidianDeep centre with an Ember rim that cools to Scorch over a few seconds, then
-- is cleaned up. Without the cleanup the floor fills with rims and the newest slam stops reading.
function Arena.addCrater(self, at: Vector3, radius: number)
	local y = self.floorTopY + 0.05
	local centre = part(self.model, "Crater", C.ObsidianDeep, Enum.Material.Basalt,
		Vector3.new(radius * 1.6, 0.3, radius * 1.6),
		CFrame.new(at.X, y, at.Z), false)
	centre.Shape = Enum.PartType.Cylinder
	centre.CFrame = CFrame.new(at.X, y, at.Z) * CFrame.Angles(0, 0, math.pi / 2)

	local rim = part(self.model, "CraterRim", C.Ember, Enum.Material.Neon,
		Vector3.new(radius * 1.9, 0.22, radius * 1.9),
		CFrame.new(at.X, y + 0.02, at.Z), false)
	rim.Shape = Enum.PartType.Cylinder
	rim.CFrame = CFrame.new(at.X, y + 0.02, at.Z) * CFrame.Angles(0, 0, math.pi / 2)
	rim.Transparency = 0.1
	rim.Parent = centre

	table.insert(self.marks, centre)
	self:trimMarks()

	-- The rim cools from Ember to Scorch. This is the mark changing after the fact, not the dragon
	-- being animated, so hard rule 2 is untouched.
	task.spawn(function()
		local t0 = os.clock()
		local cool = ArenaConfig.IMPACT_MARK_COOL_S
		while rim.Parent and os.clock() - t0 < cool do
			local f = (os.clock() - t0) / cool
			rim.Color = C.Ember:Lerp(C.Scorch, f)
			rim.Transparency = 0.1 + 0.6 * f
			task.wait(0.05)
		end
		if rim.Parent then
			rim.Material = Enum.Material.Basalt
			rim.Color = C.Scorch
			rim.Transparency = 0.3
		end
	end)
	Debris:AddItem(centre, ArenaConfig.IMPACT_MARK_LIFETIME_S)
end

function Arena.addScorch(self, at: Vector3, radius: number)
	local patch = part(self.model, "Scorch", C.Scorch, Enum.Material.Basalt,
		Vector3.new(radius * 1.5, 0.25, radius * 1.5),
		CFrame.new(at.X, self.floorTopY + 0.04, at.Z), false)
	patch.Shape = Enum.PartType.Cylinder
	patch.CFrame = CFrame.new(at.X, self.floorTopY + 0.04, at.Z) * CFrame.Angles(0, 0, math.pi / 2)
	patch.Transparency = 0.25
	table.insert(self.marks, patch)
	self:trimMarks()
	Debris:AddItem(patch, ArenaConfig.IMPACT_MARK_LIFETIME_S)
end

-- Is this world point on the playable floor? Pickups and spawns ask, so nothing lands in the lava
-- or somewhere the dragon cannot reach.
function Arena.inBounds(self, at: Vector3): boolean
	if not self.bounds then
		return false
	end
	local b = self.bounds
	local s = Mapping.STUDS_PER_MM
	local local_ = at - Mapping.ORIGIN
	local xMm = local_.X / s
	local yMm = local_.Z / s
	return xMm > b.x0 and xMm < b.x1 and yMm > b.y0 and yMm < b.y1
end

-- A random point on the floor, inside reach, for a pickup or a spawn. Keeps clear of the pedestal
-- end, where the tip cannot get down to the floor.
function Arena.randomFloorPoint(self, rng: Random): Vector3
	local b = self.bounds
	local s = Mapping.STUDS_PER_MM
	local xMm = b.x0 + (b.x1 - b.x0) * rng:NextNumber(0.08, 0.92)
	-- The dead zone close to the base: the tip cannot reach the floor there, so nothing spawns in
	-- it. Players must never find a spot the dragon cannot hit.
	local yMm = b.y0 + (b.y1 - b.y0) * rng:NextNumber(0.3, 0.94)
	return Mapping.ORIGIN + Vector3.new(xMm * s, self.floorTopY + 3, yMm * s)
end

return Arena
