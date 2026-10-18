-- ReplicatedStorage.Core.Events
-- Game events to the real arm. Events.fire sends {t = "event", name, intensity, duration} through the
-- core's Bridge (via Core.StateStore.sendEvent, which owns the link), but only an effect the bridge's
-- hello listed in hello.effects; otherwise only the Roblox side runs (the caller does that either way).
-- Names are the protocol's: "earthquake", "mirror", "fog", ... (PROTOCOL.md). The server clamps intensity
-- and duration to its own safety caps.
--   Events.fire(name, intensity, duration) -> true if it reached the robot
--   Events.fired -> signal (BindableEvent.Event) with (name, intensity, duration, sent)

local StateStore = require(script.Parent.StateStore)

local Events = {}

local firedEvent = Instance.new("BindableEvent")
Events.fired = firedEvent.Event

function Events.fire(name, intensity, duration)
	local sent, why = StateStore.sendEvent(name, intensity, duration)
	print(string.format("[Core.Events] %s %s intensity=%s duration=%s%s", sent and "sent" or "roblox only:", name,
		tostring(intensity), tostring(duration), sent and "" or (" (" .. tostring(why) .. ")")))
	firedEvent:Fire(name, intensity, duration, sent)
	return sent
end

return Events
