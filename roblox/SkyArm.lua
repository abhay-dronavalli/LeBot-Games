--!strict
-- The giant arm that mirrors the real follower.
--
-- Python sends the arm as a stick figure of *world points* in sheet mm (one per joint centre,
-- base to tip), not as raw joint angles. That is the whole reason this file is short: there
-- are no link lengths here, no Motor6D rig to assemble, and no per-joint sign or offset to
-- discover by wiggling one real joint at a time. Each segment is simply the part that spans
-- points i and i+1. The real kinematics already ran in Python, against the arm's own URDF and
-- its fitted calibration, so the geometry is right by construction.
--
--   local SkyArm = require(script.Parent.SkyArm)
--   local arm = SkyArm.new(workspace, { thickness = 3 })
--   Bridge.onState(function(s) arm:update(s.arm) end)

local Mapping = require(script.Parent.Mapping)

local SkyArm = {}
SkyArm.__index = SkyArm

local SEGMENT_COLOR = Color3.fromRGB(205, 216, 227)
local JOINT_COLOR = Color3.fromRGB(120, 140, 170)
local TIP_COLOR = Color3.fromRGB(77, 163, 255)

local function part(parent: Instance, name: string, color: Color3, size: Vector3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false          -- the Sky Arm is scenery; the 1v1 arm is a separate rig
	p.CastShadow = true
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Size = size
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function SkyArm.new(parent: Instance, opts: any?)
	local self = setmetatable({}, SkyArm)
	opts = opts or {}
	self.thickness = opts.thickness or 3
	self.model = Instance.new("Model")
	self.model.Name = "SkyArm"
	self.model.Parent = parent
	self.segments = {} :: { BasePart }
	self.joints = {} :: { BasePart }
	self.points = {} :: { Vector3 }
	return self
end

-- One segment positioned to span a -> b. A Part's CFrame is its centre, and its length runs
-- along the local Z axis, which is what CFrame.lookAt gives, so size.Z is the span.
function SkyArm.setSegment(self, i: number, a: Vector3, b: Vector3)
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
	seg.Transparency = 0
	seg.Size = Vector3.new(self.thickness, self.thickness, span)
	seg.CFrame = CFrame.lookAt((a + b) / 2, b)
end

function SkyArm.update(self, arm: any)
	if arm == nil or arm.points == nil then
		return
	end

	local pts = {}
	for i, p in arm.points do
		pts[i] = Mapping.point(p)
	end
	self.points = pts

	for i = 1, #pts - 1 do
		self:setSegment(i, pts[i], pts[i + 1])
	end
	for i = #pts, #self.segments do
		if self.segments[i] then
			self.segments[i].Transparency = 1
		end
	end

	for i, p in pts do
		local j = self.joints[i]
		if not j then
			local last = i == #pts
			local d = self.thickness * (last and 1.6 or 1.3)
			j = part(self.model, "Joint" .. i, last and TIP_COLOR or JOINT_COLOR,
				Vector3.new(d, d, d))
			j.Shape = Enum.PartType.Ball
			self.joints[i] = j
		end
		j.CFrame = CFrame.new(p)
	end
end

-- Where the jaw tips are in the world. Hang the giant ghost block here when a real block is
-- held, and test the 1v1 grab against it.
function SkyArm.tip(self): Vector3?
	return self.points[#self.points]
end

-- For the 1v1 arm: anchored, CFrame-driven parts do not fire Touched reliably, so check the
-- overlap on the server each Heartbeat instead.
function SkyArm.partsTouching(self, params: OverlapParams?): { BasePart }
	local hits = {}
	local seen = {}
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

return SkyArm
