--!strict
-- The dragon: a crimson robot arm wearing scale armour, sitting exactly where the real SO-101 is.
--
-- A separate rig from SkyArm.lua on purpose - SkyArm's own comment says the 1v1 arm is its own
-- thing. The input is identical: `arm.points`, base to tip, converted with Mapping.point. Python
-- already ran the kinematics against the arm's URDF and fitted calibration, so there are no link
-- lengths here, no Motor6D assembly, and no per-joint sign to discover by wiggling.
--
--   local dragon = DragonArm.new(map)
--   every new state frame: dragon:update(s.arm, s.arm_age)   (Module, from Link.state())
--
-- Four things in here exist because the obvious version is wrong:
--
-- 1. BUILD ONCE, THEN MOVE. Link lengths never change - they come from forward kinematics on a
--    real URDF. So each segment is built once from the first frame's span and afterwards only
--    moved, with Model:PivotTo. Resizing a segment every frame stretches every decoration welded
--    to it: the spikes grow and shrink, and the armour plates slide.
--
-- 2. NOT CFrame.lookAt(a, b). Its default up vector is world up. In a slam the head points
--    straight down, the look direction goes parallel to world up, and the CFrame flips and spins -
--    the spikes end up underneath at the exact moment the player is watching the head. The up
--    vector here is the normal of the arm's own plane (through shoulder_lift, elbow_flex and
--    wrist_flex), which is perpendicular to every segment by construction and is defined no matter
--    where the head points. When the arm straightens that plane degenerates, so the previous
--    frame's normal is kept rather than snapping to something arbitrary.
--
-- 3. HEAD ROLL COMES FROM THE JOINT, NOT THE POINTS. Three points on a line say nothing about
--    rotation about that line, so the head's roll is read from arm.joints.wrist_roll directly.
--
-- 4. THE JAW'S RANGE IS LEARNED, NOT ASSUMED. Mirrors bridge/world.py `_grip_state`: what counts
--    as "open" depends on the gripper and its calibration, so a fixed percentage that is wrong for
--    this arm pins the jaw shut forever and the dragon never breathes fire.
--
-- Hard rule 2 governs this whole file: the dragon is always where the real arm is. Nothing in here
-- tweens, eases, bobs or recoils. If the visual drifts off the hitbox, hits look unfair - and
-- under `earthquake` the real arm is already shaking, so adding shake on top would double it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Mapping = require(script.Parent.Mapping)

local DragonArm = {}
DragonArm.__index = DragonArm

local C = Theme.Color

-- Segment index -> what it is. Point i to point i+1, with arm.points base to tip.
local SEGMENTS = {
	{ name = "Shoulders",  thickness = 16, spikes = 0, plates = 2 },
	{ name = "LowerNeck",  thickness = 14, spikes = 5, plates = 3 },
	{ name = "UpperNeck",  thickness = 12, spikes = 4, plates = 3 },
	{ name = "Skull",      thickness = 11, spikes = 0, plates = 1 },
	{ name = "Head",       thickness = 12, spikes = 0, plates = 0 },
}

local HEAD_INDEX = 5

-- A decoration: seen, never hit. The core segment parts are the hitbox, and nothing else may be,
-- or "what you see is what hits" (hard rule 3) stops being true.
local function decor(parent: Instance, name: string, color: Color3, size: Vector3,
	material: Enum.Material?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.Material = material or Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function DragonArm.new(parent: Instance)
	local self = setmetatable({}, DragonArm)
	self.model = Instance.new("Model")
	self.model.Name = "Dragon"
	self.model.Parent = parent

	self.segments = {} :: { any }     -- [i] = { model, core, length, decor... }
	self.joints = {} :: { Model }
	self.built = false
	self.normal = Vector3.new(0, 1, 0)   -- last good arm-plane normal; kept when the arm straightens
	self.points = {} :: { Vector3 }

	-- The jaw's observed range, learned as it runs (see _jawFraction).
	self.gripLo = nil :: number?
	self.gripHi = nil :: number?
	self.jawFrac = 0

	self.dormant = false
	self.pedestal = nil :: Model?
	return self
end

-- Learned jaw opening, 0 (shut) to 1 (as open as this gripper has ever been seen).
--
-- Straight from bridge/world.py `_grip_state`, and for the same reason: absolute thresholds are a
-- trap, because the reading that means "open" differs from arm to arm. Once the jaw has been seen
-- both open and shut the span is known and the fraction is correct for any gripper with no
-- measurement step. Until the span is meaningful, fall back to the fixed percentage.
function DragonArm.jawFraction(self, grip: number?): number
	if grip == nil then
		return 0
	end
	self.gripLo = self.gripLo and math.min(self.gripLo, grip) or grip
	self.gripHi = self.gripHi and math.max(self.gripHi, grip) or grip
	local span = (self.gripHi :: number) - (self.gripLo :: number)
	if span >= ArenaConfig.GRIP_SPAN_MIN then
		return math.clamp((grip - (self.gripLo :: number)) / span, 0, 1)
	end
	return math.clamp(grip / ArenaConfig.GRIP_OPEN_PCT, 0, 1)
end

-- The raw gripper reading the jaw fraction was computed from. AttackDetect needs both: the
-- fraction for "is this jaw open for this arm", the raw percent for the butterfingers floor.
function DragonArm.gripSpan(self): (number?, number?)
	return self.gripLo, self.gripHi
end

-- The normal of the plane through shoulder_lift, elbow_flex and wrist_flex. This is "up" for every
-- segment, so the spikes stay on top however the arm is pointing. Undefined when those three are
-- collinear (a straight arm), and the previous frame's value is kept rather than snapping.
function DragonArm.planeNormal(self, pts: { Vector3 }): Vector3
	if #pts < 4 then
		return self.normal
	end
	local n = (pts[3] - pts[2]):Cross(pts[4] - pts[3])
	if n.Magnitude < 1e-3 then
		return self.normal                 -- arm straight: the plane is undefined, keep the last
	end
	self.normal = n.Unit
	return self.normal
end

-- ---------------------------------------------------------------------------------------------
-- Building. Everything below runs once, on the first frame that carries a full set of points.
-- ---------------------------------------------------------------------------------------------

-- A segment is a Model whose parts are laid out in local space: the core runs along +Z, centred at
-- the origin, so the Model's pivot is the segment's midpoint and PivotTo(CFrame.lookAt(mid, b, up))
-- puts it exactly on the arm.
function DragonArm.buildSegment(self, i: number, span: number): any
	local spec = SEGMENTS[i]
	local t = spec.thickness
	local model = Instance.new("Model")
	model.Name = spec.name
	model.Parent = self.model

	-- The core is the hitbox, and the only part in the dragon that answers a query. Everything
	-- else hangs off it as decoration.
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = true                  -- this is what GetPartsInPart finds
	core.CanTouch = false
	core.CastShadow = true
	core.Material = Enum.Material.SmoothPlastic
	core.Color = C.DragonScale
	core.Size = Vector3.new(t, t * 0.85, span)
	core.TopSurface = Enum.SurfaceType.Smooth
	core.BottomSurface = Enum.SurfaceType.Smooth
	core.Parent = model
	model.PrimaryPart = core

	local seg = { model = model, core = core, length = span, spec = spec, parts = {} }

	-- Underside, so the silhouette has a dark belly under the lit plates.
	local belly = decor(model, "Belly", C.DragonShade, Vector3.new(t * 0.92, t * 0.3, span * 0.98))
	seg.belly = belly

	-- Overlapping armour plates along the top. Chunky and smooth, Roblox plastic, not texture.
	seg.plates = {}
	for k = 1, spec.plates do
		local f = (k - 0.5) / spec.plates
		local plate = decor(model, "Plate" .. k, C.DragonScale,
			Vector3.new(t * 1.06, t * 0.34, span / spec.plates * 1.15))
		seg.plates[k] = { part = plate, z = (f - 0.5) * span, y = t * 0.4 }
	end

	-- A row of spikes along the top: half of what makes the silhouette unmistakable against the
	-- sky (the horns are the other half).
	seg.spikes = {}
	for k = 1, spec.spikes do
		local f = (k - 0.5) / spec.spikes
		local spike = decor(model, "Spike" .. k, C.DragonSpike,
			Vector3.new(t * 0.22, t * 0.62, t * 0.3))
		spike.Shape = Enum.PartType.Wedge
		seg.spikes[k] = { part = spike, z = (f - 0.5) * span, y = t * 0.62 }
	end

	return seg
end

-- The head: a wedge longer than it is wide. The upper jaw is fixed to the skull; the lower jaw is
-- hinged at the *back* of the head and swings open with the gripper.
function DragonArm.buildHead(self, seg: any)
	local t = seg.spec.thickness
	local span = seg.length
	local model = seg.model

	seg.core.Size = Vector3.new(t, t * 0.78, span)
	seg.core.Transparency = 1          -- the jaws are the visible head; the core is just the hitbox

	local upper = decor(model, "UpperJaw", C.DragonScale, Vector3.new(t, t * 0.42, span))
	seg.upper = upper

	local lower = decor(model, "LowerJaw", C.DragonShade, Vector3.new(t * 0.9, t * 0.34, span * 0.92))
	seg.lower = lower
	seg.hingeZ = -span / 2 + t * 0.1   -- back of the head, so the jaw opens downward and forward

	-- The mouth glows more as the jaw opens. Mostly transparent when shut, so a closed dragon is
	-- not a lamp.
	local maw = decor(model, "Maw", C.DragonEye, Vector3.new(t * 0.72, t * 0.3, span * 0.8),
		Enum.Material.Neon)
	maw.Transparency = 1
	seg.maw = maw

	local light = Instance.new("PointLight")
	light.Name = "MouthLight"
	light.Color = C.Lava
	light.Range = 30
	light.Brightness = 0
	light.Enabled = false
	light.Parent = maw
	seg.mouthLight = light

	-- Where the fire comes from, pointing along the head's forward axis (wrist_roll -> tip).
	local mouth = Instance.new("Attachment")
	mouth.Name = "Mouth"
	mouth.CFrame = CFrame.new(0, 0, span / 2)
	mouth.Parent = seg.core
	seg.mouth = mouth

	seg.eyes = {}
	for k = -1, 1, 2 do
		local eye = decor(model, "Eye" .. (k < 0 and "L" or "R"), C.DragonEye,
			Vector3.new(t * 0.2, t * 0.2, t * 0.2), Enum.Material.Neon)
		eye.Shape = Enum.PartType.Ball
		table.insert(seg.eyes, { part = eye, x = k * t * 0.32, y = t * 0.24, z = span * 0.16 })
	end

	seg.teeth = {}
	for k = 1, 6 do
		local side = (k % 2 == 0) and 1 or -1
		local f = math.ceil(k / 2) / 3.5
		local tooth = decor(model, "Tooth" .. k, C.DragonTooth,
			Vector3.new(t * 0.09, t * 0.16, t * 0.12))
		table.insert(seg.teeth, { part = tooth, x = side * t * 0.34, z = span * (0.5 - f * 0.4) })
	end

	seg.horns = {}
	for k = -1, 1, 2 do
		local horn = decor(model, "Horn" .. (k < 0 and "L" or "R"), C.DragonSpike,
			Vector3.new(t * 0.18, t * 0.9, t * 0.26))
		horn.Shape = Enum.PartType.Wedge
		table.insert(seg.horns, { part = horn, x = k * t * 0.3, y = t * 0.5, z = -span * 0.34 })
	end
end

-- An iron ring with bolts at every joint. This is where the machine shows through the dragon, and
-- it is the detail that keeps the neck from reading as the smooth serpent the concept art shows.
function DragonArm.buildJoint(self, i: number, diameter: number): Model
	local model = Instance.new("Model")
	model.Name = "Joint" .. i
	model.Parent = self.model

	local ring = decor(model, "Ring", C.DragonIron,
		Vector3.new(diameter, diameter * 0.3, diameter), Enum.Material.DiamondPlate)
	ring.Shape = Enum.PartType.Cylinder
	model.PrimaryPart = ring

	for k = 1, 4 do
		local a = (k / 4) * math.pi * 2
		local bolt = decor(model, "Bolt" .. k, C.DragonIron,
			Vector3.new(diameter * 0.11, diameter * 0.11, diameter * 0.11), Enum.Material.Metal)
		bolt:SetAttribute("OffsetY", math.cos(a) * diameter * 0.46)
		bolt:SetAttribute("OffsetZ", math.sin(a) * diameter * 0.46)
	end
	return model
end

-- The base point sits on a wide bolted iron drum, sunk into rock, with Neon cracks around its foot.
function DragonArm.buildPedestal(self, base: Vector3, diameter: number)
	local model = Instance.new("Model")
	model.Name = "Pedestal"
	model.Parent = self.model

	local drum = decor(model, "Drum", C.DragonIron,
		Vector3.new(diameter * 1.5, diameter * 1.1, diameter * 1.5), Enum.Material.DiamondPlate)
	drum.Shape = Enum.PartType.Cylinder
	drum.CFrame = CFrame.new(base - Vector3.new(0, diameter * 0.5, 0)) * CFrame.Angles(0, 0, math.pi / 2)

	for k = 1, 6 do
		local a = (k / 6) * math.pi * 2
		local bolt = decor(model, "Bolt" .. k, C.DragonIron,
			Vector3.new(diameter * 0.14, diameter * 0.14, diameter * 0.14), Enum.Material.Metal)
		bolt.CFrame = CFrame.new(base
			+ Vector3.new(math.cos(a) * diameter * 0.72, -diameter * 0.1, math.sin(a) * diameter * 0.72))
	end

	for k = 1, 4 do
		local a = (k / 4) * math.pi * 2 + 0.4
		local crack = decor(model, "Crack" .. k, C.Ember,
			Vector3.new(diameter * 0.12, 0.2, diameter * 0.9), Enum.Material.Neon)
		crack.Transparency = 0.35
		crack.CFrame = CFrame.new(base
			+ Vector3.new(math.cos(a) * diameter, -diameter * 1.02, math.sin(a) * diameter))
			* CFrame.Angles(0, -a, 0)
	end
	self.pedestal = model
end

function DragonArm.build(self, pts: { Vector3 })
	for i = 1, math.min(#pts - 1, #SEGMENTS) do
		local span = (pts[i + 1] - pts[i]).Magnitude
		local seg = self:buildSegment(i, span)
		if i == HEAD_INDEX then
			self:buildHead(seg)
		end
		self.segments[i] = seg
	end
	for i = 1, #pts do
		local d = (SEGMENTS[math.min(i, #SEGMENTS)].thickness) * 1.18
		self.joints[i] = self:buildJoint(i, d)
	end
	self:buildPedestal(pts[1], SEGMENTS[1].thickness)
	self.built = true
end

-- ---------------------------------------------------------------------------------------------
-- Moving. Every frame, no interpolation.
-- ---------------------------------------------------------------------------------------------

function DragonArm.placeSegment(self, i: number, a: Vector3, b: Vector3, up: Vector3, roll: number)
	local seg = self.segments[i]
	if not seg then
		return
	end
	local dir = b - a
	if dir.Magnitude < 1e-3 then
		return
	end
	-- lookAt orthogonalises `up` against the look direction. The plane normal is already
	-- perpendicular to every segment, so nothing is lost - but a segment exactly along the normal
	-- would be ambiguous, which is why the normal is a *plane* normal and not an arbitrary axis.
	local base = CFrame.lookAt((a + b) / 2, b, up)
	if roll ~= 0 then
		base = base * CFrame.Angles(0, 0, roll)
	end
	seg.model:PivotTo(base)

	local t = seg.spec.thickness
	-- Decorations are positioned from the model's pivot each frame rather than welded, so a part
	-- destroyed by anything else recovers on the next frame instead of leaving a hole.
	seg.belly.CFrame = base * CFrame.new(0, -t * 0.32, 0)
	for _, pl in seg.plates do
		pl.part.CFrame = base * CFrame.new(0, pl.y, pl.z)
	end
	for _, sp in seg.spikes do
		sp.part.CFrame = base * CFrame.new(0, sp.y, sp.z) * CFrame.Angles(-math.pi / 2, 0, 0)
	end

	if i == HEAD_INDEX then
		self:placeHead(seg, base)
	end
end

function DragonArm.placeHead(self, seg: any, base: CFrame)
	local t = seg.spec.thickness
	local span = seg.length

	seg.upper.CFrame = base * CFrame.new(0, t * 0.2, 0)

	-- The lower jaw swings about the hinge at the back of the head. Rotating about the hinge, not
	-- about the jaw's own centre, is what makes it read as a jaw rather than a sliding plate.
	local angle = math.rad(ArenaConfig.JAW_MAX_DEG) * self.jawFrac
	local hinge = base * CFrame.new(0, -t * 0.08, seg.hingeZ)
	seg.lower.CFrame = hinge * CFrame.Angles(angle, 0, 0) * CFrame.new(0, 0, span * 0.46)

	-- Glow grows with the opening. This shows the arm's *current* state, which hard rule 1 allows -
	-- it is not a wind-up, and it cannot predict where the operator will strike.
	seg.maw.CFrame = hinge * CFrame.Angles(angle / 2, 0, 0) * CFrame.new(0, 0, span * 0.4)
	seg.maw.Transparency = 1 - 0.85 * self.jawFrac
	seg.mouthLight.Enabled = self.jawFrac > 0.05
	seg.mouthLight.Brightness = 3 * self.jawFrac

	for _, e in seg.eyes do
		e.part.CFrame = base * CFrame.new(e.x, e.y, e.z)
	end
	for _, th in seg.teeth do
		th.part.CFrame = base * CFrame.new(th.x, t * 0.04, th.z)
	end
	for _, h in seg.horns do
		h.part.CFrame = base * CFrame.new(h.x, h.y, h.z) * CFrame.Angles(-math.pi / 2.6, 0, 0)
	end
end

function DragonArm.placeJoint(self, i: number, at: Vector3, dir: Vector3, up: Vector3)
	local model = self.joints[i]
	if not model then
		return
	end
	local cf = CFrame.lookAt(at, at + dir, up) * CFrame.Angles(0, math.pi / 2, 0)
	model:PivotTo(cf)
	for _, bolt in model:GetChildren() do
		if bolt:IsA("BasePart") and bolt.Name ~= "Ring" then
			bolt.CFrame = cf * CFrame.new(0,
				bolt:GetAttribute("OffsetY") :: number, bolt:GetAttribute("OffsetZ") :: number)
		end
	end
end

-- Dormant: a stale arm is a harmless dragon (hard rule 5). The body goes to DragonShade, the eyes
-- go out, and AttackDetect stops dealing damage. The dragon does *not* move to a rest pose - it
-- stays exactly where the last real frame put it, because moving it would be animating the dragon
-- locally, and a player standing clear of a dead dragon should not have it drift onto them.
function DragonArm.setDormant(self, dormant: boolean)
	if dormant == self.dormant then
		return
	end
	self.dormant = dormant

	for i, seg in self.segments do
		seg.core.Color = dormant and C.DragonShade or C.DragonScale
		if i ~= HEAD_INDEX then
			for _, pl in seg.plates do
				pl.part.Color = dormant and C.DragonShade or C.DragonScale
			end
		end
	end
	local head = self.segments[HEAD_INDEX]
	if head then
		head.upper.Color = dormant and C.DragonShade or C.DragonScale
		for _, e in head.eyes do
			e.part.Material = dormant and Enum.Material.SmoothPlastic or Enum.Material.Neon
			e.part.Color = dormant and C.DragonSpike or C.DragonEye
		end
		head.maw.Transparency = dormant and 1 or head.maw.Transparency
		head.mouthLight.Enabled = not dormant and head.mouthLight.Enabled
	end
end

function DragonArm.update(self, arm: any, armAge: number?)
	if arm == nil or arm.points == nil or #arm.points < 2 then
		return
	end

	local pts = table.create(#arm.points)
	for i, p in arm.points do
		pts[i] = Mapping.point(p)
	end
	self.points = pts

	if not self.built then
		self:build(pts)
	end

	self.jawFrac = self:jawFraction(arm.joints and arm.joints.gripper)
	local up = self:planeNormal(pts)

	-- Head roll comes from the joint: three points on a line say nothing about rotation about that
	-- line. Check the sign once against the real arm - roll the wrist and confirm the head turns
	-- the same way - and flip it here if it is backwards, not in the mapping.
	local roll = math.rad(arm.joints and arm.joints.wrist_roll or 0)

	for i = 1, math.min(#pts - 1, #self.segments) do
		self:placeSegment(i, pts[i], pts[i + 1], up, i == HEAD_INDEX and roll or 0)
	end
	for i = 1, math.min(#pts, #self.joints) do
		local dir = (i < #pts) and (pts[i + 1] - pts[i]) or (pts[i] - pts[i - 1])
		self:placeJoint(i, pts[i], dir, up)
	end

	self:setDormant((armAge or 0) > ArenaConfig.STALE_ARM_S)
end

-- Where the jaw tips are. The last point, same as arm.tip.
function DragonArm.tip(self): Vector3?
	return self.points[#self.points]
end

function DragonArm.headCFrame(self): CFrame?
	local seg = self.segments[HEAD_INDEX]
	return seg and seg.model:GetPivot() or nil
end

function DragonArm.mouthAttachment(self): Attachment?
	local seg = self.segments[HEAD_INDEX]
	return seg and seg.mouth or nil
end

function DragonArm.isDormant(self): boolean
	return self.dormant
end

-- Overlap against the core segment parts. Anchored, CFrame-driven parts do not fire Touched
-- reliably, so the server checks the overlap itself each Heartbeat - the same approach
-- SkyArm:partsTouching takes. Only the cores are tested, so this is exactly the drawn body and
-- never a hidden radius around it.
function DragonArm.partsTouching(self, params: OverlapParams?): { BasePart }
	local hits, seen = {}, {}
	for _, seg in self.segments do
		for _, hit in workspace:GetPartsInPart(seg.core, params) do
			if not seen[hit] then
				seen[hit] = true
				table.insert(hits, hit)
			end
		end
	end
	return hits
end

return DragonArm
