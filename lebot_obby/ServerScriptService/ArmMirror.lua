-- ArmMirror -- the giant arm that IS player 2. Adapted from the bridge branch's SkyArm.
--
-- Renamed from SkyArm on purpose: ServerScriptService.SkyArm is the obby's own IK rig, which
-- *simulates* an operator by animating a crate delivery. There is a real operator now, so the
-- two cannot both drive the same bay -- an animated reach would re-enact something player 2
-- already did with their hands. SkyArm stays as the solo/DebugMode path; this is the live one,
-- and only one is visible at a time (see setVisible).
--
-- Python sends the arm as a stick figure of *world points* in sheet mm (one per joint centre,
-- base to tip), not as raw joint angles. That is why this file is short: no link lengths, no
-- Motor6D rig to assemble, and no per-joint sign or offset to discover by wiggling one real
-- joint at a time. Segment i is simply the part spanning points i and i+1. The real kinematics
-- already ran in Python against the arm's own URDF and its fitted calibration, so the geometry
-- is right by construction.
--
--   local ArmMirror = require(game.ServerScriptService.ArmMirror)
--   local arm = ArmMirror.new(workspace)
--   Bridge.onState(function(s) arm:update(s.arm, s.arm_age) end)
--
-- Shape of the thing, which is not what Config.GantryHeight expects: the real SO-101's pan
-- axis is 69 mm off the paper and its wrist reaches 306 mm, so at the mat-to-bay scale this is
-- a 43-stud arm whose shoulder sits 9.7 studs up. It is a table arm reaching up and over, not
-- a gantry arm hanging down. Mapping puts its base at the bay's centre column, 9.3 studs
-- *before* the entrance edge, so it stands on the catwalk and towers over the bay.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Mapping = require(ReplicatedStorage:WaitForChild("Mapping"))

local ArmMirror = {}
ArmMirror.__index = ArmMirror

local SEGMENT_COLOR = Color3.fromRGB(242, 242, 240)   -- printed PLA, as SkyArm uses
local JOINT_COLOR = Color3.fromRGB(30, 30, 32)        -- Feetech STS3215 servo bodies
local TIP_COLOR = Color3.fromRGB(77, 163, 255)
local STALE_COLOR = Color3.fromRGB(96, 98, 104)

-- Cross-section of the real links: Upper_arm_SO101 is 67.54 x 24.67 mm. Expressed in mm so it
-- tracks the mat scale automatically instead of being a stud constant that rots when the scale
-- is retuned.
local LINK_W_MM, LINK_D_MM = 67.54, 24.67

local function part(parent, name, color, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false          -- scenery: the player never stands on the arm itself
	p.CanQuery = false            -- and must never be picked up by a reach-gating raycast
	p.CastShadow = true
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function ArmMirror.new(parent, opts)
	local self = setmetatable({}, ArmMirror)
	opts = opts or {}
	self.linkWmm = opts.linkWmm or LINK_W_MM
	self.linkDmm = opts.linkDmm or LINK_D_MM
	self.model = Instance.new("Model")
	self.model.Name = "ArmMirror"
	self.model.Parent = parent
	self.segments = {}
	self.joints = {}
	self.points = {}
	self.stale = false
	self.visible = true

	-- The pan axis sits ~9.7 studs above the floor, so without something underneath it the arm
	-- reads as floating. A plinth is also honest: the real arm is bolted to the table beside
	-- the mat, not hanging from anything.
	self.plinth = part(self.model, "Plinth", Color3.fromRGB(46, 48, 54), Vector3.new(1, 1, 1))
	self.plinth.Material = Enum.Material.DiamondPlate
	return self
end

function ArmMirror.setVisible(self, visible)
	self.visible = visible
	self.model.Parent = visible and workspace or nil
end

-- One segment positioned to span a -> b. A Part's CFrame is its centre and CFrame.lookAt
-- points the local Z axis down the span, so size.Z is the length.
function ArmMirror.setSegment(self, i, a, b)
	local seg = self.segments[i]
	if not seg then
		seg = part(self.model, "Segment" .. i, SEGMENT_COLOR, Vector3.new(1, 1, 1))
		self.segments[i] = seg
	end
	local span = (b - a).Magnitude
	if span < 0.01 then
		seg.Transparency = 1
		return
	end
	local s = Mapping.STUDS_PER_MM
	seg.Transparency = 0
	seg.Color = self.stale and STALE_COLOR or SEGMENT_COLOR
	seg.Size = Vector3.new(self.linkWmm * s, self.linkDmm * s, span)
	seg.CFrame = CFrame.lookAt((a + b) / 2, b)
end

function ArmMirror.update(self, arm, age)
	if arm == nil or arm.points == nil then
		return
	end

	-- A stale pose is worse than no pose: the arm sits confidently in a position the real one
	-- left seconds ago. Blocks update slower than the arm (perception ~10 Hz vs 30 Hz) and both
	-- ages climb on a servo-bus dropout, which robot/teleop_monitored.py documents happening
	-- 37-220 s into sustained motion. So grey out rather than lie.
	self.stale = (tonumber(age) or 0) > (Config.StaleAfterSeconds or 2)

	local pts = {}
	for i, p in arm.points do
		pts[i] = Mapping.point(p)
	end
	self.points = pts
	if #pts == 0 then
		return
	end

	for i = 1, #pts - 1 do
		self:setSegment(i, pts[i], pts[i + 1])
	end
	for i = #pts, #self.segments do
		if self.segments[i] then
			self.segments[i].Transparency = 1
		end
	end

	local s = Mapping.STUDS_PER_MM
	for i, p in pts do
		local j = self.joints[i]
		if not j then
			local last = i == #pts
			local d = self.linkWmm * s * (last and 0.75 or 0.6)
			j = part(self.model, "Joint" .. i, last and TIP_COLOR or JOINT_COLOR,
				Vector3.new(d, d, d))
			j.Shape = Enum.PartType.Ball
			self.joints[i] = j
		end
		j.Color = self.stale and STALE_COLOR or (i == #pts and TIP_COLOR or JOINT_COLOR)
		j.CFrame = CFrame.new(p)
	end

	-- Plinth: from the bay floor up to the pan axis, under the base point.
	local base = pts[1]
	local floorY = Mapping.ORIGIN.Y
	local h = math.max(0.2, base.Y - floorY)
	local w = self.linkWmm * s * 1.4
	self.plinth.Size = Vector3.new(w, h, w)
	self.plinth.CFrame = CFrame.new(base.X, floorY + h / 2, base.Z)
end

-- Where the jaw tips are. The held-block platform hangs here, and this is the hook the 1v1
-- arena grab tests against.
function ArmMirror.tip(self)
	return self.points[#self.points]
end

-- Anchored, CFrame-driven parts do not fire Touched reliably, so overlap is checked on the
-- server each Heartbeat instead.
function ArmMirror.partsTouching(self, params)
	local hits, seen = {}, {}
	for _, seg in self.segments do
		if seg.Transparency < 1 then
			for _, hit in workspace:GetPartsInPart(seg, params) do
				if not seen[hit] then
					seen[hit] = true
					table.insert(hits, hit)
				end
			end
		end
	end
	return hits
end

return ArmMirror
