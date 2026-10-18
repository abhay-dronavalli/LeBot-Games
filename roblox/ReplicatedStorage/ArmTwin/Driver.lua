-- ReplicatedStorage.ArmTwin.Driver
-- Drives an ArmTwin rig from real arm angles: { shoulder_pan, shoulder_lift, elbow_flex, wrist_flex,
-- wrist_roll } in degrees and gripper 0..100 (closed..open), as in plan.md's state message.
-- Config.twinJoints gives each joint a sign and a zero offset (degrees, or percent for the gripper), so
-- the twin can be tuned at the table by moving one real joint at a time.
--   Driver.serve(remote, getArm, hz)  server: broadcast getArm() hz times a second (default 20)
--   Driver.attach(model, remote)      client: ease toward each sample every Heartbeat and set the Motor6Ds
--   Driver.rigAngles(arm, tuning)     degrees -> rig radians (tuning defaults to Config.twinJoints)
--   Driver.pose(model, rigAngles)     set the rig's Motor6D Transforms
--   Driver.tip(arm, tuning)           where the gripper tip is for those angles (model frame, studs)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)
local Rig = require(script.Parent.Rig)

local SMOOTHING = 12 -- per second; higher follows samples more tightly

local Driver = {}

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

-- Client side. Returns a handle: handle.destroy() stops it, handle.current() is the eased pose.
function Driver.attach(model, remote)
	local motors = motorsOf(model, true)
	local current = Driver.rigAngles({})
	local target = Driver.rigAngles({})
	local connections = {}
	table.insert(connections, remote.OnClientEvent:Connect(function(arm)
		if type(arm) == "table" then
			target = Driver.rigAngles(arm)
		end
	end))
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		local k = 1 - math.exp(-SMOOTHING * dt)
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
