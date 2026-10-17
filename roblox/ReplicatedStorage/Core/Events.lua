-- ReplicatedStorage.Core.Events
-- STAND-IN. The core teammate will wire Events.fire to the WebSocket bridge, sending
-- {t = "event", name, intensity, duration} to Python (plan.md section 2). Until then it prints and
-- fires a local signal. Event names match plan.md: "earthquake", "mirror", "fog".
--   Events.fire(name, intensity, duration)
--   Events.fired -> signal (BindableEvent.Event) with (name, intensity, duration)

local Events = {}

local firedEvent = Instance.new("BindableEvent")
Events.fired = firedEvent.Event

function Events.fire(name, intensity, duration)
	print(string.format("[Core.Events] fire %s intensity=%s duration=%s", name, tostring(intensity), tostring(duration)))
	firedEvent:Fire(name, intensity, duration)
end

return Events
