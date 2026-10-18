--!strict
-- The link to the robot laptop. A ModuleScript, required from a server Script.
--
-- Roblox connects *out* to the Python process, which is the server. Nothing sits in between.
-- Enable Game Settings -> Security -> Allow HTTP Requests first.
--
--   local Bridge = require(game.ServerScriptService.Bridge)
--   Bridge.connect("ws://localhost:8765")     -- or the robot laptop's LAN IP
--   Bridge.onState(function(state) ... end)
--   Bridge.sendEvent("earthquake", 0.7, 4)
--
-- Two things this handles that are easy to get wrong:
--
-- Backpressure. Python sends 30 state frames a second whether or not anything reads them. If
-- a frame handler is slower than that, frames queue and the game drifts behind reality. So
-- MessageReceived only *stores* the newest state; the game reads it on Heartbeat. A dropped
-- frame is correct behaviour here: the next one is always more current.
--
-- Reconnecting. The robot process restarts constantly during a hackathon, and the servo bus
-- on this rig drops out under load. A lost link must never need a Studio restart.

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Bridge = {}

local ws: any = nil
local url: string = "ws://localhost:8765"
local connected = false
local retryAt = 0
local RETRY_S = 2

local latest: any = nil          -- newest state frame, replaced not queued
local helloFrame: any = nil
local stateHandlers: { (any) -> () } = {}
local helloHandlers: { (any) -> () } = {}

Bridge.framesReceived = 0
Bridge.framesApplied = 0

function Bridge.onState(fn: (any) -> ())
	table.insert(stateHandlers, fn)
end

function Bridge.onHello(fn: (any) -> ())
	table.insert(helloHandlers, fn)
	if helloFrame then
		fn(helloFrame)
	end
end

function Bridge.hello(): any
	return helloFrame
end

function Bridge.isConnected(): boolean
	return connected
end

local function handle(raw: string)
	local ok, frame = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(frame) ~= "table" then
		warn("[Bridge] undecodable frame")
		return
	end
	if frame.t == "state" then
		Bridge.framesReceived += 1
		latest = frame                  -- replace, never queue
	elseif frame.t == "hello" then
		helloFrame = frame
		print(("[Bridge] hello: source=%s protocol v%d, %d effects")
			:format(tostring(frame.source), frame.v or 0, #(frame.effects or {})))
		for _, fn in helloHandlers do
			task.spawn(fn, frame)
		end
	elseif frame.t == "error" then
		warn("[Bridge] server error: " .. tostring(frame.message))
	end
end

local function open()
	local ok, client = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, { Url = url })
	end)
	if not ok then
		warn("[Bridge] could not create the client: " .. tostring(client))
		return false
	end
	ws = client
	connected = true
	print("[Bridge] connected to " .. url)

	ws.MessageReceived:Connect(handle)
	-- Not every engine version exposes the same closure signal, so bind whatever is there.
	local closed = (ws :: any).Closed or (ws :: any).Disconnected
	if closed then
		closed:Connect(function()
			connected = false
			ws = nil
			retryAt = os.clock() + RETRY_S
			warn("[Bridge] link closed; retrying")
		end)
	end
	return true
end

function Bridge.connect(wsUrl: string?)
	url = wsUrl or url
	if not open() then
		retryAt = os.clock() + RETRY_S
	end

	RunService.Heartbeat:Connect(function()
		if not connected then
			if os.clock() >= retryAt then
				retryAt = os.clock() + RETRY_S
				open()
			end
			return
		end

		local frame = latest
		if frame == nil then
			return
		end
		latest = nil
		Bridge.framesApplied += 1
		for _, fn in stateHandlers do
			local ok, err = pcall(fn, frame)
			if not ok then
				warn("[Bridge] a state handler errored: " .. tostring(err))
			end
		end
	end)
end

function Bridge.send(frame: any): boolean
	if not connected or ws == nil then
		return false
	end
	local ok, err = pcall(function()
		ws:Send(HttpService:JSONEncode(frame))
	end)
	if not ok then
		warn("[Bridge] send failed: " .. tostring(err))
		connected = false
		retryAt = os.clock() + RETRY_S
	end
	return ok
end

-- Make something happen to the real arm. Python clamps intensity and duration to safe caps,
-- so a wrong number here cannot damage the hardware.
function Bridge.sendEvent(name: string, intensity: number?, duration: number?): boolean
	return Bridge.send({
		t = "event",
		name = name,
		intensity = intensity or 1.0,
		duration = duration or 3.0,
	})
end

function Bridge.sendMode(name: string, level: number?): boolean
	return Bridge.send({ t = "mode", name = name, level = level })
end

return Bridge
