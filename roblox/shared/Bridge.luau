-- Studio location: ServerStorage.Shared.Bridge (ModuleScript)
--[[
	The arcade's handle on the robot link. It opens no socket: the core's ServerScriptService.Bridge is
	the only connection, owned by ReplicatedStorage.Core.StateStore, which connects once on the server to
	ReplicatedStorage.PatternMatch.Config.bridgeUrl when it is first required.

	  Bridge.start()     ArcadeManager calls it once: makes sure the core link is up (requires
	                     Core.StateStore; idempotent) and keeps ReplicatedStorage.Arcade.ArmOnline in step
	                     with the core link. Safe to call more than once.
	  Bridge.send(msg)   sends a protocol frame through the core link. {t = "event", ...} goes through
	                     Core.StateStore.sendEvent (only effects the bridge's hello lists); anything else
	                     ({t = "mode", ...}) through the core Bridge's send. Returns true if it went out.
	                     While the link is down, or the core runs its fake generator, frames are dropped
	                     (one warn per server run).
	  Bridge.isOnline()  true while Core.StateStore.status() is "live" or "mock"; false for "offline",
	                     "fake" or still pending. ArmOnline mirrors it (polled every 0.25 s), so the
	                     cabinet screens show ARM OFFLINE / MOCK MODE when there is no robot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local POLL_S = 0.25

local Bridge = {}

local core = nil       -- ReplicatedStorage.Core.StateStore
local coreBridge = nil -- ServerScriptService.Bridge (the one socket), once found
local started = false
local warnedDrop = false

local function coreStore()
	if not core then
		core = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("StateStore"))
	end
	return core
end

function Bridge.isOnline()
	local status = coreStore().status()
	return status == "live" or status == "mock"
end

local function setOnline(on)
	local arcade = ReplicatedStorage:FindFirstChild("Arcade")
	if arcade and arcade:GetAttribute("ArmOnline") ~= on then
		arcade:SetAttribute("ArmOnline", on)
	end
end

function Bridge.start()
	coreStore() -- requiring Core.StateStore is what connects (server, running only)
	if started then
		return
	end
	started = true
	setOnline(false)
	if not RunService:IsRunning() then
		return
	end
	task.spawn(function()
		while true do
			setOnline(Bridge.isOnline())
			task.wait(POLL_S)
		end
	end)
end

local function dropped(msg, why)
	if not warnedDrop then
		warnedDrop = true
		warn(string.format("[Shared.Bridge] robot link not up (%s): dropping %s frames until it is",
			tostring(why), tostring(type(msg) == "table" and msg.t or msg)))
	end
	return false
end

function Bridge.send(msg)
	if type(msg) ~= "table" then
		return false
	end
	local store = coreStore()
	if not Bridge.isOnline() then
		return dropped(msg, store.status())
	end
	if msg.t == "event" then
		local ok, why = store.sendEvent(msg.name, msg.intensity, msg.duration)
		if not ok and why ~= "not in hello.effects" then
			return dropped(msg, why)
		end
		return ok == true
	end
	if not coreBridge then
		local module = ServerScriptService:FindFirstChild("Bridge")
		local ok, result = false, nil
		if module then
			ok, result = pcall(require, module)
		end
		if not ok or type(result) ~= "table" then
			return dropped(msg, "no ServerScriptService.Bridge")
		end
		coreBridge = result
	end
	if not coreBridge.send(msg) then
		return dropped(msg, "send failed")
	end
	return true
end

return Bridge
