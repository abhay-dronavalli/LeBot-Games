--!strict
-- The arena's view of the robot. It opens no socket: the arcade owns the one robot connection, and
-- this only reads ServerStorage.Shared.StateStore and sends through ServerStorage.Shared.Bridge
-- (docs/arcade-plan.md, "Mode contract"). The standalone arena called Bridge.connect itself and got
-- each frame pushed to it; here the mode pulls the newest state every Heartbeat instead.
--
-- The dragon needs the frame as the robot sends it (arm.points in sheet mm, arm_age, effects), not
-- the arcade's converted shape, so it reads Shared.StateStore.raw() / .hello(). A place whose
-- Shared.StateStore predates those two accessors gets the same data from the store they wrap,
-- ReplicatedStorage.Core.StateStore, which is what Shared.StateStore requires anyway; neither
-- path connects anything.
--
--   Link.state()      -> the newest state frame (same table until a new one arrives), with arm.tip
--                        filled in from the last arm point when the frame has none (the core's fake
--                        generator sends points only)
--   Link.hello()      -> the bridge's hello frame, or nil (no robot yet, or the core's fake generator)
--   Link.status()     -> "live" | "mock" | "offline" | "fake"
--   Link.sendEvent(name, intensity, duration) -> true if it went to the robot

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ServerStorage:WaitForChild("Shared")
local SharedStore = require(Shared:WaitForChild("StateStore")) :: any
local SharedBridge = require(Shared:WaitForChild("Bridge")) :: any
local Core = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("StateStore")) :: any

local Link = {}

local lastRaw = nil :: any
local lastOut = nil :: any

local function raw(): any
	if type(SharedStore.raw) == "function" then
		return SharedStore.raw()
	end
	return Core.get()
end

function Link.state(): any
	local s = raw()
	if s == lastRaw then
		return lastOut
	end
	lastRaw = s
	local out = s
	local arm = type(s) == "table" and s.arm or nil
	if type(arm) == "table" and arm.tip == nil and type(arm.points) == "table" and #arm.points > 0 then
		-- Copied, not written into: the frame belongs to the core, and Pattern Match reads it too.
		out = table.clone(s)
		out.arm = table.clone(arm)
		local tip = arm.points[#arm.points]
		out.arm.tip = { x = tip.x, y = tip.y, z = tip.z }
	end
	lastOut = out
	return out
end

function Link.hello(): any
	if type(SharedStore.hello) == "function" then
		return SharedStore.hello()
	end
	return Core.hello()
end

function Link.status(): string
	return Core.status()
end

function Link.sendEvent(name: string, intensity: number?, duration: number?): boolean
	return SharedBridge.send({ t = "event", name = name, intensity = intensity, duration = duration }) == true
end

return Link
