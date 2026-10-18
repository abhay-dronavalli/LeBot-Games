-- SkyArm -- a giant SO-101-style arm hanging from the ceiling gantry rails that physically
-- carries crates into place. Idle motion and the reach/grip/carry/release sequence both run
-- through the same forward-kinematics rig, so swapping the fake idle driver for the real robot
-- feed later only changes where target angles come from, not how the rig renders.
-- Not a true 6-DOF solver: the IK is a simplified 2-link-planar-arm-plus-azimuth solve, enough
-- to reach convincingly into any of the 12 cells while keeping real-robot-style joint
-- names/conventions (shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local SkyArm = {}

-- Proportions come from the real SO-101 teleop arm in the repo
-- (BROKER-2-so-101-teleop-arm-2.3mf, orobot.io). Real part dims, in mm:
--   Upper_arm_SO101            142.46 x 67.54 x 24.67
--   Under_arm_SO101            130.70 x 64.40 x 24.00
--   Rotation_Pitch_SO101        46.00 x 84.20 x 59.80
--   Wrist_Roll_SO101            42.85 x 52.00 x 65.20
--   Wrist_Roll_Follower_SO101  105.43 x 52.00 x 65.20
--   Moving_Jaw_SO101            49.34 x 94.57 x 20.00
--   Base_SO101                 110.92 x 72.00 x 87.00
--   Motor_holder_SO101_Base     55.08 x 38.10 x 28.00
-- The leader-only Handle_SO101/Trigger_SO101 are deliberately omitted -- the Sky Arm is the
-- follower, not the thing the operator holds.
-- Link lengths are sized to the actual working envelope, not blown up to full scale: the arm
-- only ever needs ~15.9 studs of reach (far corner cell, 14.4 across and 6.6 down), and links
-- much longer than that force a huge elbow bend that folds up through the roofline.
-- The trolley slides in X to sit above the target column, like a real gantry crane, so the arm
-- only ever spans the row offset (<= 8 studs) instead of half the bay width. That's what lets
-- these links be ~35% shorter than a fixed centre-mounted arm would need.
local L1 = 6.2    -- Upper_arm_SO101
local L2 = 5.69   -- Under_arm_SO101 (L2/L1 = 0.918, matching the real 130.70/142.46)
local MM = L1 / 142.46 -- studs per mm, derived so every other part scales off the real model

-- Wrist stack is deliberately shorter than true scale (real Wrist_Roll_Follower is 105mm);
-- at full proportion the gripper alone would eat most of the shoulder-to-floor drop.
local WRIST_LEN = 2.0 -- Wrist_Roll_SO101
local BODY_LEN = 1.9  -- Wrist_Roll_Follower_SO101 (gripper body)
local JAW_LEN = 1.9   -- Moving_Jaw_SO101

-- wrist_flex is solved to keep the wrist/gripper pointing straight down, so this much extra
-- drop always happens past the forearm tip.
local GRIP_REACH = WRIST_LEN + BODY_LEN + JAW_LEN * 0.6

-- Where the shoulder PITCH axis sits below the carriage. solveIK and applyFK must agree on
-- this or the gripper lands short.
local MOUNT_Y = 0.6
local BASE_H = 1.6
local YOKE_H = 1.7
local SHOULDER_OFFSET = MOUNT_Y + BASE_H + YOKE_H

-- Crates are 4 studs tall and the gripper takes them from above, so every reach aims at the
-- crate's top face rather than the floor. MIN_TARGET_Y is a hard floor so the jaw tips can
-- never punch through the map even if a caller asks for something lower.
local CRATE_GRIP_HEIGHT = 4.2
local MIN_TARGET_Y = JAW_LEN * 0.4 + 0.3

-- Trolley travel limits: it rides the two rail beams, so it stays between the outer columns.
local TROLLEY_MIN_X = Config.CellSize / 2
local TROLLEY_MAX_X = Config.BayWidth - Config.CellSize / 2

local UPPER_W, UPPER_T = 67.54 * MM, 24.67 * MM
local FORE_W, FORE_T = 64.40 * MM, 24.00 * MM

local WHITE = Color3.fromRGB(242, 242, 240) -- printed PLA
local SERVO = Color3.fromRGB(30, 30, 32)    -- Feetech STS3215 bodies

local carriageY = Config.GantryHeight

----------------------------------------------------------------
-- Build the rig once (idempotent -- re-requiring the module doesn't rebuild it)
----------------------------------------------------------------
local rigFolder = Workspace:FindFirstChild("SkyArmRig")
if rigFolder then
	rigFolder:Destroy()
end
rigFolder = Instance.new("Folder")
rigFolder.Name = "SkyArmRig"
rigFolder.Parent = Workspace

local function newPart(name, size, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = material or Enum.Material.SmoothPlastic
	part.Color = color or WHITE
	part.Size = size
	part.Parent = rigFolder
	return part
end

-- Gantry bridge: spans the bay between the two rail beams and carries the trolley
local bridge = newPart("Bridge", Vector3.new(Config.BayWidth, 1.2, 2), Color3.fromRGB(70, 75, 85), Enum.Material.Metal)

local carriage = newPart("Carriage", Vector3.new(4, 1.5, 3.4), Color3.fromRGB(60, 60, 68), Enum.Material.Metal)
carriage.CFrame = CFrame.new(Config.BayWidth / 2, carriageY, Config.BayDepth / 2)

-- Base_SO101 + its motor holder, mounted upside down under the gantry carriage
local baseHousing = newPart("BaseHousing", Vector3.new(110.92 * MM, BASE_H, 87.00 * MM), WHITE)
local panServo = newPart("PanServo", Vector3.new(55.08 * MM, 38.10 * MM, 28.00 * MM), SERVO)

-- Rotation_Pitch_SO101: the chunky shoulder yoke that carries the pitch axis
local shoulderYoke = newPart("ShoulderYoke", Vector3.new(46.00 * MM, YOKE_H, 59.80 * MM), WHITE)
local shoulderServo = newPart("ShoulderServo", Vector3.new(55.08 * MM, 38.10 * MM, 28.00 * MM), SERVO)

-- The arm links are flat plates on the real robot, not rods: thin across the pitch axis (X),
-- tall in the swing plane (Y), long down the chain (Z).
local upperArm = newPart("UpperArm", Vector3.new(UPPER_T, UPPER_W, L1), WHITE)
local elbowServo = newPart("ElbowServo", Vector3.new(55.08 * MM, 38.10 * MM, 28.00 * MM), SERVO)
local forearm = newPart("Forearm", Vector3.new(FORE_T, FORE_W, L2), WHITE)
local wristServo = newPart("WristServo", Vector3.new(56.39 * MM, 36.90 * MM, 28.00 * MM), SERVO)

local wristRoll = newPart("WristRoll", Vector3.new(42.85 * MM, 52.00 * MM, WRIST_LEN), WHITE)
local gripperBody = newPart("GripperBody", Vector3.new(42.85 * MM, 52.00 * MM, BODY_LEN), WHITE)
local jawStatic = newPart("JawStatic", Vector3.new(20.00 * MM, 49.34 * MM, JAW_LEN), WHITE)
local jawMoving = newPart("JawMoving", Vector3.new(20.00 * MM, 49.34 * MM, JAW_LEN), WHITE)

----------------------------------------------------------------
-- Forward kinematics -- given joint angles (degrees), place every segment.
-- shoulder_pan = azimuth around Y. shoulder_lift = pitch below horizontal (0 = reach straight
-- out, 90 = straight down). elbow_flex = relative bend at the elbow (0 = forearm continues
-- straight from the upper arm). Every angle compounds through the chain like a real robot's
-- joint-local convention.
----------------------------------------------------------------
local gripperTipWorld = carriage.Position

local function applyFK(angles)
	-- the bridge rides the rails at the trolley's Z, spanning the full bay width
	bridge.CFrame = CFrame.new(Config.BayWidth / 2, carriageY + 1.35, carriage.Position.Z)

	local mountTop = carriage.CFrame * CFrame.new(0, -MOUNT_Y, 0)
	baseHousing.CFrame = mountTop * CFrame.new(0, -BASE_H / 2, 0)

	-- shoulder_pan turns the whole arm about the vertical axis
	local panPivot = mountTop * CFrame.new(0, -BASE_H, 0) * CFrame.Angles(0, math.rad(angles.shoulder_pan), 0)
	panServo.CFrame = panPivot * CFrame.new(0, 0.5, 0)
	shoulderYoke.CFrame = panPivot * CFrame.new(0, -YOKE_H / 2, 0)

	-- shoulder pitch -- this point must match solveIK's base (SHOULDER_OFFSET below the carriage)
	local upperArmJoint = panPivot * CFrame.new(0, -YOKE_H, 0)
		* CFrame.Angles(-math.rad(angles.shoulder_lift), 0, 0)
	shoulderServo.CFrame = upperArmJoint
	upperArm.CFrame = upperArmJoint * CFrame.new(0, 0, -L1 / 2)

	local elbowJoint = upperArmJoint * CFrame.new(0, 0, -L1) * CFrame.Angles(-math.rad(angles.elbow_flex), 0, 0)
	elbowServo.CFrame = elbowJoint
	forearm.CFrame = elbowJoint * CFrame.new(0, 0, -L2 / 2)

	local wristJoint = elbowJoint * CFrame.new(0, 0, -L2)
		* CFrame.Angles(-math.rad(angles.wrist_flex), 0, 0)
		* CFrame.Angles(0, 0, math.rad(angles.wrist_roll))
	wristServo.CFrame = wristJoint
	wristRoll.CFrame = wristJoint * CFrame.new(0, 0, -WRIST_LEN / 2)
	gripperBody.CFrame = wristJoint * CFrame.new(0, 0, -WRIST_LEN - BODY_LEN / 2)

	-- Parallel jaws: Moving_Jaw rides in, the fixed jaw mirrors it
	local jawRoot = wristJoint * CFrame.new(0, 0, -WRIST_LEN - BODY_LEN)
	-- Closed hugs a 4-stud crate rather than clipping through it; open clears it.
	local openAmount = 2.05 + (1 - angles.gripper / 100) * 0.95
	jawStatic.CFrame = jawRoot * CFrame.new(openAmount, 0, -JAW_LEN / 2)
	jawMoving.CFrame = jawRoot * CFrame.new(-openAmount, 0, -JAW_LEN / 2)

	gripperTipWorld = (jawRoot * CFrame.new(0, 0, -JAW_LEN * 0.6)).Position
end

----------------------------------------------------------------
-- Inverse kinematics -- simplified 2-link planar solve + azimuth, aimed at a world position.
----------------------------------------------------------------
local function solveIK(targetWorldPos)
	-- never let a caller drive the gripper through the floor
	if targetWorldPos.Y < MIN_TARGET_Y then
		targetWorldPos = Vector3.new(targetWorldPos.X, MIN_TARGET_Y, targetWorldPos.Z)
	end

	local base = (carriage.CFrame * CFrame.new(0, -SHOULDER_OFFSET, 0)).Position
	local delta = targetWorldPos - base
	local azimuth = math.deg(math.atan2(-delta.X, -delta.Z))

	local horizontalDist = math.sqrt(delta.X ^ 2 + delta.Z ^ 2)
	local drop = -delta.Y - GRIP_REACH -- positive when target is below the base; shortened because
	-- the gripper itself covers the last GRIP_REACH studs pointing straight down

	local reach = math.sqrt(horizontalDist ^ 2 + drop ^ 2)
	reach = math.clamp(reach, math.abs(L1 - L2) + 0.5, L1 + L2 - 0.5)

	local cosElbow = (reach ^ 2 - L1 ^ 2 - L2 ^ 2) / (2 * L1 * L2)
	local elbow = math.deg(math.acos(math.clamp(cosElbow, -1, 1)))

	local alpha = math.atan2(drop, horizontalDist)
	local beta = math.atan2(L2 * math.sin(math.rad(elbow)), L1 + L2 * math.cos(math.rad(elbow)))
	local shoulderLift = math.deg(alpha - beta)

	return {
		shoulder_pan = azimuth,
		shoulder_lift = shoulderLift,
		elbow_flex = elbow,
		wrist_flex = -(shoulderLift + elbow) + 90,
		wrist_roll = 0,
	}
end

local function solveIKWithGripper(pos, gripperVal)
	local angles = solveIK(pos)
	angles.gripper = gripperVal
	return angles
end

-- Debug helpers -- quick numeric verification instead of guessing from screenshots.
-- Safe to leave in; harmless if never called.
function SkyArm.debugGripperPos()
	return gripperTipWorld
end

function SkyArm.debugSolve(pos)
	return solveIK(pos)
end

----------------------------------------------------------------
-- Angle interpolation / idle loop
----------------------------------------------------------------
-- Park pose is solved rather than hand-tuned, so it stays correct if the link lengths change.
-- Gripper parks ~7 studs below and ~7 ahead of the shoulder, well clear of the floor.
local function copyAngles(a)
	return {
		shoulder_pan = a.shoulder_pan, shoulder_lift = a.shoulder_lift, elbow_flex = a.elbow_flex,
		wrist_flex = a.wrist_flex, wrist_roll = a.wrist_roll, gripper = a.gripper,
	}
end

local IDLE_ANGLES = solveIKWithGripper(
	carriage.Position + Vector3.new(0, -SHOULDER_OFFSET - 7.05, -8),
	20
)

local current = copyAngles(IDLE_ANGLES)
local target = copyAngles(IDLE_ANGLES)

-- Place the whole rig before the first frame renders. Without this every part sits at the
-- world origin for one frame and the arm visibly flashes through the floor on spawn.
applyFK(current)

local busy = false
local heldCrate = nil

RunService.Heartbeat:Connect(function(dt)
	local alpha = math.clamp(dt * 4.0, 0, 1)
	for key in pairs(current) do
		current[key] += (target[key] - current[key]) * alpha
	end
	applyFK(current)

	if heldCrate and heldCrate.Parent and heldCrate:FindFirstChild("Base") then
		local base = heldCrate.Base
		base.CFrame = CFrame.new(gripperTipWorld - Vector3.new(0, base.Size.Y / 2 + 0.5, 0))
		local stripe = heldCrate:FindFirstChild("Stripe")
		if stripe then
			stripe.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + 0.05, 0)
		end
		local topper = heldCrate:FindFirstChild("Topper")
		if topper then
			topper.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + topper.Size.Y / 2, 0)
			local topperStripe = heldCrate:FindFirstChild("TopperStripe")
			if topperStripe then
				topperStripe.CFrame = topper.CFrame * CFrame.new(0, topper.Size.Y / 2 + 0.05, 0)
			end
		end
	end

	if not busy then
		local t = os.clock()
		target.shoulder_pan = math.sin(t * 0.15) * 15
		target.shoulder_lift = IDLE_ANGLES.shoulder_lift + math.sin(t * 0.2 + 1) * 6
		target.elbow_flex = IDLE_ANGLES.elbow_flex + math.sin(t * 0.18 + 2) * 8
		target.wrist_flex = IDLE_ANGLES.wrist_flex + math.sin(t * 0.25) * 5
		target.wrist_roll = math.sin(t * 0.1) * 20
		target.gripper = IDLE_ANGLES.gripper
	end
end)

local function angleError(a, b)
	local sum = 0
	for key in pairs(a) do
		sum += math.abs(a[key] - b[key])
	end
	return sum
end

local function moveTo(angles, timeout)
	for key, v in pairs(angles) do
		target[key] = v
	end
	local elapsed = 0
	while angleError(current, target) > 1.5 and elapsed < (timeout or 1.5) do
		task.wait(0.03)
		elapsed += 0.03
	end
end

return SkyArm
