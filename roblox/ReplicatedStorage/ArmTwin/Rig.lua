-- ReplicatedStorage.ArmTwin.Rig
-- The SO-101 twin's geometry, forward kinematics and part builder. Link lengths come from
-- Config.twinLinksCm (cm, from the SO-101 URDF) and the cm -> stud scale from the boards
-- (Config.boardCellStuds per Config.cellSizeMm), so the twin's reach over the LiveBoard matches the real
-- arm's reach over the printed grid.
-- The game draws the twin from the bridge's arm.points now (ArmTwin.Stick); this rig and its Motor6Ds
-- stay built in the place, hidden, and its FK still gives the stick figure's rest pose (chainPoints) and
-- the fake generator's arm.
--
-- Model frame: origin at the base's bottom center (the Model's pivot), +Y up, -Z forward (toward the
-- board), +X right. Rest pose (all joints 0): the arm reaches straight forward, horizontal, at
-- shoulder height. Joints, in the real order, with their axes (right-hand rule):
--   shoulder_pan   Y   positive turns the arm left (counterclockwise seen from above)
--   shoulder_lift  X   positive pitches the upper arm up
--   elbow_flex     X   positive bends the forearm up
--   wrist_flex     X   positive pitches the hand up
--   wrist_roll     Z   positive rolls the hand about the forearm axis
--   gripper       -Y   positive swings the moving jaw open
-- Each joint is a Motor6D named after it (Part0 = parent link, Part1 = child link) with translation-only
-- C0/C1, so Transform = CFrame.fromAxisAngle(axis, angle) turns the child about the joint.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.PatternMatch.Config)

local WHITE = Color3.fromHex("e9e6df") -- links, jaws, base: Apprentice's off-white arm parts
local DARK = Color3.fromHex("2a2d33")  -- joints, shoulder, hand: Apprentice's dark arm parts
local JAW_OFFSET_CM = 1.2 -- each jaw sits this far to the side of the hand's center line

local Rig = {}
Rig.JOINTS = { "shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper" }
Rig.CHAIN = { "shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll" } -- base to tip
Rig.AXES = {
	shoulder_pan = Vector3.yAxis,
	shoulder_lift = Vector3.xAxis,
	elbow_flex = Vector3.xAxis,
	wrist_flex = Vector3.xAxis,
	wrist_roll = Vector3.zAxis,
	gripper = -Vector3.yAxis,
}
Rig.GRIPPER_OPEN = math.rad(60) -- moving jaw angle at gripper = 100
-- arm.points names, base to tip, as the bridge sends them (PROTOCOL.md): the five chain joints and the tip
Rig.POINT_NAMES = { "shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "tip" }

function Rig.studsPerCm()
	return Config.boardCellStuds / Config.cellSizeMm * 10
end

-- Joint positions at rest and the gripper tip, in cm in the model frame.
function Rig.jointsCm()
	local L = Config.twinLinksCm
	local y = L.baseHeight + L.shoulderHeight
	local p = {}
	p.shoulder_pan = Vector3.new(0, L.baseHeight, 0)
	p.shoulder_lift = Vector3.new(0, y, 0)
	p.elbow_flex = Vector3.new(0, y, -L.upperArm)
	p.wrist_flex = Vector3.new(0, y, -(L.upperArm + L.forearm))
	p.wrist_roll = Vector3.new(0, y, -(L.upperArm + L.forearm + L.wrist))
	p.gripper = p.wrist_roll + Vector3.new(JAW_OFFSET_CM, 0, -L.jawHinge)
	p.tip = p.wrist_roll + Vector3.new(0, 0, -L.gripper)
	return p
end

-- Forward kinematics: rig angles (radians, by joint name) -> gripper tip CFrame in the model frame.
-- In studs, or in cm when `cm` is true. Same chain the Motor6Ds apply.
function Rig.forward(angles, cm)
	local p = Rig.jointsCm()
	local s = cm and 1 or Rig.studsPerCm()
	local cf = CFrame.new()
	local prev = Vector3.zero
	for _, name in ipairs(Rig.CHAIN) do
		cf = cf * CFrame.new((p[name] - prev) * s) * CFrame.fromAxisAngle(Rig.AXES[name], angles[name] or 0)
		prev = p[name]
	end
	return cf * CFrame.new((p.tip - prev) * s)
end

-- Forward kinematics for every point: rig angles -> the five chain joints' positions and the tip, base to
-- tip (Rig.POINT_NAMES), in the model frame. In studs, or in cm when `cm` is true.
function Rig.chainPoints(angles, cm)
	local p = Rig.jointsCm()
	local s = cm and 1 or Rig.studsPerCm()
	local cf = CFrame.new()
	local prev = Vector3.zero
	local points = {}
	for _, name in ipairs(Rig.CHAIN) do
		cf = cf * CFrame.new((p[name] - prev) * s)
		table.insert(points, cf.Position)
		cf = cf * CFrame.fromAxisAngle(Rig.AXES[name], angles[name] or 0)
		prev = p[name]
	end
	table.insert(points, (cf * CFrame.new((p.tip - prev) * s)).Position)
	return points
end

-- Fills `model` with the twin's parts and Motor6Ds (blocky SO-101: white links, dark joints) and sets
-- its pivot to the base's bottom center. The base is anchored; every other part hangs off it through
-- the joints, so the whole arm follows the base when the model is moved.
function Rig.build(model)
	local s = Rig.studsPerCm()
	local L = Config.twinLinksCm
	local p = Rig.jointsCm()

	local function part(name, sizeCm, centerCm, color, anchored)
		local x = Instance.new("Part")
		x.Name = name
		x.Size = sizeCm * s
		x.CFrame = CFrame.new(centerCm * s)
		x.Color = color
		x.Material = Enum.Material.SmoothPlastic
		x.Anchored = anchored == true
		x.CanCollide = false
		x.CanTouch = false
		x.CanQuery = false
		x.Massless = true
		x.TopSurface = Enum.SurfaceType.Smooth
		x.BottomSurface = Enum.SurfaceType.Smooth
		x.Parent = model
		return x
	end
	local function motor(name, part0, part1, jointCm)
		local m = Instance.new("Motor6D")
		m.Name = name
		m.Part0 = part0
		m.Part1 = part1
		m.C0 = CFrame.new(jointCm * s - part0.Position) -- parts are axis-aligned at rest
		m.C1 = CFrame.new(jointCm * s - part1.Position)
		m.Parent = part1
	end
	local function weld(part0, part1)
		local w = Instance.new("WeldConstraint")
		w.Part0 = part0
		w.Part1 = part1
		w.Parent = part1
	end
	-- A dark cube on a joint, welded to the child link so it turns with it.
	local function hub(name, link, jointCm, sizeCm)
		weld(link, part(name, Vector3.new(sizeCm, sizeCm, sizeCm), jointCm, DARK))
	end

	local base = part("Base", Vector3.new(9, L.baseHeight, 9), Vector3.new(0, L.baseHeight / 2, 0), WHITE, true)
	local shoulder = part("Shoulder", Vector3.new(5.5, L.shoulderHeight, 5.5),
		Vector3.new(0, L.baseHeight + L.shoulderHeight / 2, 0), DARK)
	motor("shoulder_pan", base, shoulder, p.shoulder_pan)

	local upperArm = part("UpperArm", Vector3.new(3.4, 3.4, L.upperArm), (p.shoulder_lift + p.elbow_flex) / 2, WHITE)
	hub("ShoulderHub", upperArm, p.shoulder_lift, 4.6)
	motor("shoulder_lift", shoulder, upperArm, p.shoulder_lift)

	local forearm = part("Forearm", Vector3.new(3, 3, L.forearm), (p.elbow_flex + p.wrist_flex) / 2, WHITE)
	hub("ElbowHub", forearm, p.elbow_flex, 4)
	motor("elbow_flex", upperArm, forearm, p.elbow_flex)

	local wrist = part("Wrist", Vector3.new(2.8, 2.8, L.wrist), (p.wrist_flex + p.wrist_roll) / 2, WHITE)
	hub("WristHub", wrist, p.wrist_flex, 3.6)
	motor("wrist_flex", forearm, wrist, p.wrist_flex)

	-- Hand (the wrist_roll link): a dark palm with the fixed jaw; the moving jaw hinges off it.
	local handCenter = p.wrist_roll + Vector3.new(0, 0, -L.jawHinge / 2)
	local hand = part("Hand", Vector3.new(4, 2.8, L.jawHinge), handCenter, DARK)
	motor("wrist_roll", wrist, hand, p.wrist_roll)
	local jawLength = L.gripper - L.jawHinge
	local jawCenterZ = p.wrist_roll.Z - L.jawHinge - jawLength / 2
	local fixedJaw = part("FixedJaw", Vector3.new(0.9, 2, jawLength),
		Vector3.new(-JAW_OFFSET_CM, p.wrist_roll.Y, jawCenterZ), WHITE)
	weld(hand, fixedJaw)
	local movingJaw = part("MovingJaw", Vector3.new(0.9, 2, jawLength),
		Vector3.new(JAW_OFFSET_CM, p.wrist_roll.Y, jawCenterZ), WHITE)
	motor("gripper", hand, movingJaw, p.gripper)

	local tip = Instance.new("Attachment") -- the gripper tip, for FK checks; between the jaw ends
	tip.Name = "Tip"
	tip.Position = (p.tip - handCenter) * s
	tip.Parent = hand

	model.WorldPivot = CFrame.new()
	return model
end

return Rig
