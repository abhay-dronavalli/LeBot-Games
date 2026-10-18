-- ServerStorage.Modes.Obby.Server.SkyArm (ModuleScript)
-- SkyArm (Section 2.1, 7, 10.2 step 8 pulled forward) -- a giant SO-101-style arm hanging from
-- the ceiling gantry rails that physically carries crates into place. Idle motion and the
-- reach/grip/carry/release sequence both run through the same forward-kinematics rig, so
-- swapping the fake idle driver for the real robot feed later (Section 9) only changes where
-- target angles come from, not how the rig renders.
-- Not a true 6-DOF solver: the IK below is a simplified 2-link-planar-arm-plus-azimuth solve,
-- enough to reach convincingly into any of the 12 cells while keeping real-robot-style joint
-- names/conventions (shoulder_pan, shoulder_lift, elbow_flex, wrist_flex, wrist_roll, gripper).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))
local Mapping = require(script.Parent:WaitForChild("Mapping"))
local RunControl = require(script.Parent:WaitForChild("RunControl"))

local session = RunControl.session

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

-- Every reach aims at the crate's TOP face rather than the floor, because the gripper takes it
-- from above. Cube-derived rather than the old flat 4.2, so it follows the mat scale.
-- MIN_TARGET_Y is a hard floor so the jaw tips can never punch through the map even if a
-- caller asks for something lower.

local MIN_TARGET_Y = JAW_LEN * 0.4 + 0.3

local function gripHeight()
	return Mapping.cubeStuds() + 0.2
end

-- Trolley travel limits: it rides the two rail beams, so it stays between the outer columns.
local TROLLEY_MIN_X = Config.CellSize / 2
local TROLLEY_MAX_X = Config.BayWidth - Config.CellSize / 2

local UPPER_W, UPPER_T = 67.54 * MM, 24.67 * MM
local FORE_W, FORE_T = 64.40 * MM, 24.00 * MM

local WHITE = Color3.fromRGB(242, 242, 240) -- printed PLA
local SERVO = Color3.fromRGB(30, 30, 32)    -- Feetech STS3215 bodies

local carriageY = Config.GantryHeight

----------------------------------------------------------------
-- Build the rig once per round, INSIDE the round's map (never Workspace), so it goes when the
-- map does. Idempotent: a rig already in the map is replaced, not doubled.
----------------------------------------------------------------
local rigFolder = session.map:FindFirstChild("SkyArmRig")
if rigFolder then
	rigFolder:Destroy()
end
rigFolder = Instance.new("Folder")
rigFolder.Name = "SkyArmRig"
rigFolder.Parent = session.map

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
-- over the middle of bay 1 (bayZStart adds the map's Config.OriginZ)
carriage.CFrame = CFrame.new(Config.BayWidth / 2, carriageY, RunControl.bayZStart(1) + Config.BayDepth / 2)

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
	-- Closed hugs the cube rather than clipping through it; open clears it. This was a flat
	-- 2.05, sized by hand for the old 4-stud crate -- against a real 6.72-stud cube the jaws
	-- closed INSIDE it. Derived from the cube now, so it follows the mat scale automatically.
	local half = Mapping.cubeStuds() / 2
	local openAmount = (half + 0.15) + (1 - angles.gripper / 100) * (half * 0.45)
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

-- Debug helpers (Section 10.1 spirit -- quick numeric verification instead of guessing from
-- screenshots). Safe to leave in; harmless if never called.
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

-- LIVE MODE -- the real arm steers this rig instead of its own job queue.
--
-- The gantry crane is the look we want: it hangs from the rails, slides along the roof between
-- bays, and its links were deliberately kept short because the trolley moves, so it fits the
-- room. A literal joint-for-joint mirror of the SO-101 does not fit the room -- it is a 43
-- stud tower. So the real arm drives this rig by its TIP: wherever the real jaw is, this jaw
-- goes, solved through the IK already here. The pose is not identical, but it reaches where
-- the real arm reaches, which is what reads as mirroring.
local liveMode = false
local liveTrolleyX = nil

function SkyArm.setLiveMode(on)
	liveMode = on and true or false
	if not liveMode then
		liveTrolleyX = nil
	end
end

function SkyArm.isLive()
	return liveMode
end

-- Point the jaw at a world position. Called every frame off the wire, so nothing here may
-- yield -- moveTrolleyTo tweens and waits, which is right for a queued job and wrong here.
function SkyArm.followTip(worldPos, gripperPct)
	if not liveMode or typeof(worldPos) ~= "Vector3" then
		return
	end
	-- Keep the jaw below its own shoulder. The real arm lifts higher than this room allows,
	-- and an arm reaching above its mount points straight through the roof.
	local ceiling = carriageY - SHOULDER_OFFSET - 1
	local y = math.clamp(worldPos.Y, MIN_TARGET_Y, ceiling)
	local clamped = Vector3.new(worldPos.X, y, worldPos.Z)

	liveTrolleyX = math.clamp(worldPos.X, TROLLEY_MIN_X, TROLLEY_MAX_X)

	local angles = solveIKWithGripper(clamped, tonumber(gripperPct) or 50)
	for key, v in pairs(angles) do
		target[key] = v
	end
end

session.track(RunService.Heartbeat:Connect(function(dt)
	-- The trolley tracks the arm instead of being tweened to a stop, so it slides continuously
	-- as the operator works across the mat.
	if liveMode and liveTrolleyX then
		local x = carriage.Position.X
		local step = math.clamp(dt * 6.0, 0, 1)
		carriage.CFrame = CFrame.new(x + (liveTrolleyX - x) * step,
			carriageY, carriage.Position.Z)
	end

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
end))

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

----------------------------------------------------------------
-- Job queue -- serializes every reach/place/remove so concurrent cell edits can't fight over
-- the one shared arm.
----------------------------------------------------------------
local jobQueue = {}
local processing = false

local function processQueue()
	if processing then
		return
	end
	processing = true
	-- session.spawn: a job still running when the round ends is cancelled with it
	session.spawn(function()
		while #jobQueue > 0 do
			local job = table.remove(jobQueue, 1)
			job()
		end
		processing = false
	end)
end

local function enqueue(job)
	table.insert(jobQueue, job)
	processQueue()
end

----------------------------------------------------------------
-- Public API
----------------------------------------------------------------
function SkyArm.setActiveBay(bayModel)
	if not bayModel then
		return
	end
	-- Centre on the middle ROW ANCHOR, not on the Floor part. An obstacle may legitimately
	-- cut the floor about -- bay 2's Void removes it over rows 0-1 entirely -- which leaves
	-- Floor.Position sitting over whatever slab survived, and parked the crane 8 studs off
	-- the bay. The Cell_c_r anchors are baked and never modified, which is why everything
	-- else positional already reads from them.
	local anchors = bayModel:FindFirstChild("CrateAnchors")
	local mid = anchors and anchors:FindFirstChild("Cell_0_1")
	local z = mid and mid.Position.Z
	if not z then
		local floor = bayModel:FindFirstChild("Floor")
		z = floor and floor.Position.Z
	end
	if not z then
		return
	end
	local goal = CFrame.new(carriage.Position.X, carriageY, z)
	local tween = TweenService:Create(carriage, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = goal})
	tween:Play()
end

-- Slides the trolley along the bridge so it sits above the target column before reaching.
local function moveTrolleyTo(x)
	local clamped = math.clamp(x, TROLLEY_MIN_X, TROLLEY_MAX_X)
	local travel = math.abs(clamped - carriage.Position.X)
	if travel < 0.05 then
		return
	end
	local duration = math.clamp(travel / 14, 0.25, 1.0)
	local goal = CFrame.new(clamped, carriageY, carriage.Position.Z)
	TweenService:Create(carriage, TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {CFrame = goal}):Play()
	task.wait(duration)
end

-- Crates stay hidden until they're actually in the gripper, otherwise they flash at the world
-- origin for a frame before the held-crate tracking positions them.
local function setCrateVisible(crateModel, visible)
	for _, d in ipairs(crateModel:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Transparency = visible and 0 or 1
		elseif d:IsA("SurfaceGui") then
			d.Enabled = visible
		end
	end
end

-- Reaches to `worldCFrame`, "grips" the already-built (but staged) crateModel, carries it down,
-- and calls onArrive right as it seats -- the caller snaps the crate's final CFrame and plays
-- its own impact effect (shockwave) from inside that callback.
function SkyArm.reachAndPlace(bayModel, worldCFrame, crateModel, level, onArrive)
	enqueue(function()
		-- a newer edit can replace this crate while it is still sitting in the queue
		if crateModel:GetAttribute("Superseded") then
			crateModel:Destroy()
			return
		end
		busy = true
		local cellPos = worldCFrame.Position
		local grip = Vector3.new(cellPos.X, cellPos.Y + gripHeight(), cellPos.Z)
		local hoverPos = grip + Vector3.new(0, 7, 0)

		crateModel.Parent = bayModel
		setCrateVisible(crateModel, false)

		moveTrolleyTo(cellPos.X)
		moveTo(solveIKWithGripper(hoverPos, 0), 1.2)

		-- take hold first, let one frame place it at the gripper, then reveal
		heldCrate = crateModel
		task.wait()
		setCrateVisible(crateModel, true)
		moveTo(solveIKWithGripper(hoverPos, 100), 0.4)

		moveTo(solveIKWithGripper(grip + Vector3.new(0, 2, 0), 100), 1.0)
		moveTo(solveIKWithGripper(grip, 100), 0.5)

		heldCrate = nil
		if onArrive then
			onArrive()
		end

		moveTo(solveIKWithGripper(hoverPos, 0), 0.8)
		moveTo(IDLE_ANGLES, 1.0)
		busy = false
	end)
end

-- Reaches to the existing crate at `worldCFrame`, grips and lifts it clear (calling onLifted),
-- carries it off, then destroys it.
function SkyArm.reachAndRemove(bayModel, worldCFrame, crateModel, onLifted)
	enqueue(function()
		busy = true
		local cellPos = worldCFrame.Position
		local grip = Vector3.new(cellPos.X, cellPos.Y + gripHeight(), cellPos.Z)
		local hoverPos = grip + Vector3.new(0, 7, 0)

		moveTrolleyTo(cellPos.X)
		moveTo(solveIKWithGripper(grip, 0), 1.0)
		moveTo(solveIKWithGripper(grip, 100), 0.4)
		heldCrate = crateModel

		moveTo(solveIKWithGripper(hoverPos, 100), 1.0)
		if onLifted then
			onLifted()
		end

		local disposePos = hoverPos + Vector3.new(0, 0, -6)
		moveTo(solveIKWithGripper(disposePos, 100), 0.8)
		heldCrate = nil
		if crateModel.Parent then
			crateModel:Destroy()
		end

		moveTo(IDLE_ANGLES, 1.0)
		busy = false
	end)
end

return SkyArm
