-- ReplicatedStorage.ArmTwin.Driver
-- Drives an ArmTwin rig from real arm angles: { shoulder_pan, shoulder_lift, elbow_flex, wrist_flex,
-- wrist_roll } in degrees and gripper 0..100 (closed..open), as in plan.md's state message.
-- Config.twinJoints gives each joint a sign and a zero offset (degrees, or percent for the gripper), so
-- the twin can be tuned at the table by moving one real joint at a time.
--   Driver.serve(remote, getArm, hz)  server: broadcast getArm() hz times a second (default 20); a nil
--                                     getArm() sends nothing, so clients time out to the rest pose
--   Driver.attach(model, remote)      client: ease toward each sample every Heartbeat and set the Motor6Ds;
--                                     shows the rest pose until the first sample, for an empty sample, and
--                                     once samples stop for STALE_SECONDS
--   Driver.restPose()                 Config.twinRestPose (real-arm units), a fresh copy
--   Driver.withRest(arm)              arm with every missing joint taken from the rest pose
--   Driver.rigAngles(arm, tuning)     degrees -> rig radians (tuning defaults to Config.twinJoints); a
--                                     missing joint reads as 0 here, use withRest first to get rest instead
--   Driver.pose(model, rigAngles)     set the rig's Motor6D Transforms
--   Driver.tip(arm, tuning)           where the gripper tip is for those angles (model frame, studs)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)
local Rig = require(script.Parent.Rig)

local SMOOTHING = 12      -- per second; higher follows samples more tightly
local REST_SMOOTHING = 3  -- per second; slower settle into the rest pose when the data goes away
local STALE_SECONDS = 1   -- no sample for this long -> ease back to the rest pose

local Driver = {}
Driver.STALE_SECONDS = STALE_SECONDS

function Driver.restPose()
	return table.clone(Config.twinRestPose or {})
end

function Driver.withRest(arm)
	local out = Driver.restPose()
	if type(arm) == "table" then
		for _, name in ipairs(Rig.JOINTS) do
			if type(arm[name]) == "number" then
				out[name] = arm[name]
			end
		end
	end
	return out
end

-- True when a sample carries at least one joint value.
local function hasData(arm)
	if type(arm) ~= "table" then
		return false
	end
	for _, name in ipairs(Rig.JOINTS) do
		if type(arm[name]) == "number" then
			return true
		end
	end
	return false
end
Driver.hasData = hasData

function Driver.rigAngles(arm, tuning)
	tuning = tuning or Config.twinJoints
	local out = {}
	for _, name in ipairs(Rig.JOINTS) do
		local tune = tuning[name] or {}
		local value = (arm[name] or 0) * (tune.sign or 1) + (tune.offset or 0)
		if name == "gripper" then
			out[name] = math.clamp(value, 0, 100) / 100 * Rig.GRIPPER_OPEN
		else
			out[name] = math.rad(value)
		end
	end
	return out
end

function Driver.tip(arm, tuning)
	return Rig.forward(Driver.rigAngles(arm, tuning))
end

-- The six Motor6Ds by joint name. With `wait`, yields until they all exist: on a client the Model can
-- arrive before its parts and joints have replicated.
local function motorsOf(model, wait)
	local motors = {}
	for _, name in ipairs(Rig.JOINTS) do
		local motor = model:FindFirstChild(name, true)
		while wait and not motor do
			task.wait()
			motor = model:FindFirstChild(name, true)
		end
		motors[name] = motor
	end
	return motors
end

function Driver.pose(model, angles)
	for name, motor in pairs(motorsOf(model)) do
		motor.Transform = CFrame.fromAxisAngle(Rig.AXES[name], angles[name] or 0)
	end
end

-- Client side. Returns a handle: handle.destroy() stops it, handle.current() is the eased pose,
-- handle.resting() is true while it shows the rest pose (no sample yet, an empty one, or stale data).
-- Starts in the rest pose. A sample with joint values sets the target (missing joints from the rest
-- pose); an empty or non-table sample, or STALE_SECONDS without one, eases back to rest.
function Driver.attach(model, remote)
	local motors = motorsOf(model, true)
	local rest = Driver.rigAngles(Driver.restPose())
	local current = table.clone(rest)
	local target = rest
	local lastSample = nil -- os.clock() of the last sample with data; nil while resting
	local connections = {}
	table.insert(connections, remote.OnClientEvent:Connect(function(arm)
		if hasData(arm) then
			target = Driver.rigAngles(Driver.withRest(arm))
			lastSample = os.clock()
		else
			target = rest
			lastSample = nil
		end
	end))
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		if lastSample and os.clock() - lastSample > STALE_SECONDS then
			target = rest
			lastSample = nil
		end
		local k = 1 - math.exp(-(lastSample and SMOOTHING or REST_SMOOTHING) * dt)
		for name, goal in pairs(target) do
			current[name] += (goal - current[name]) * k
		end
		for name, motor in pairs(motors) do
			motor.Transform = CFrame.fromAxisAngle(Rig.AXES[name], current[name])
		end
	end))
	return {
		destroy = function()
			for _, c in ipairs(connections) do
				c:Disconnect()
			end
		end,
		current = function()
			return current
		end,
		resting = function()
			return lastSample == nil
		end,
	}
end

-- Server side. Returns a function that stops the broadcast.
function Driver.serve(remote, getArm, hz)
	local running = true
	task.spawn(function()
		local interval = 1 / (hz or 20)
		while running do
			task.wait(interval)
			local arm = getArm()
			if arm then
				remote:FireAllClients(arm)
			end
		end
	end)
	return function()
		running = false
	end
end

return Driver
