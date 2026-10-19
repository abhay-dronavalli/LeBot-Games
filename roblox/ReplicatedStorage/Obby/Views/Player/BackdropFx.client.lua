-- ReplicatedStorage.Obby.Views.Player.BackdropFx (LocalScript template; Views.PlayerView clones it into
-- PlayerGui for the runner and for spectators). Arcade copy of
-- lebot_obby/StarterPlayerScripts/BackdropFx.client.lua. Only tagged parts inside workspace.ObbyMap are
-- animated: the tags are generic words and the arcade's other maps may use them too. It makes no GUI. On
-- the copy's Exiting attribute it disconnects, puts every spun part and flickered lamp back to its rest
-- state and destroys the emitters it grew.
--
-- BackdropFx (client) -- the hall moves: gears turn, lamps gutter, vents breathe steam.
--
-- ALL OF IT IS CLIENT-SIDE AND TAG-DRIVEN, which is the whole design. The backdrop is a few
-- hundred parts; animating them on the server would replicate a CFrame stream for scenery
-- nobody can touch, every frame, forever. Here it costs the server exactly nothing and the
-- generators in build/ stay pure geometry -- they tag parts, this decides what a tag means.
--
-- Tags (set by build/backdrop_props.lua and build/backdrop_hall.lua):
--   BackdropSpin    -- gears, flywheels, turbines, valve wheels. Attribute "SpinSpeed"
--                      (rad/s, default 0.6) sets rate and direction.
--   BackdropFlicker -- gas lamps, firebox glow, tesla orbs. Attribute "FlickerFast" gives
--                      the jittery electric variety instead of a slow gas gutter.
--   BackdropSteam   -- an invisible anchor that grows a steam ParticleEmitter.
--   BackdropEmber   -- an invisible anchor that grows a rising-ember emitter.
--
-- CollectionService signals mean a re-run of a generator is picked up live: parts added
-- while you are standing there start moving, and destroyed ones drop out of the loop.
--
-- WHY THE SPIN IS CFrame AND NOT A TWEEN OR A HINGE. These are anchored decorative parts
-- with no physics; a constraint would need them unanchored, and a tween per part would be
-- hundreds of TweenBase instances. One RenderStepped pass over a flat array is cheaper than
-- any of it, and it is trivially throttled by distance (below).
--
-- DISTANCE THROTTLING. Everything here is backdrop: if it is far away you cannot see a gear
-- tooth move. Parts beyond FAR_DISTANCE are skipped entirely each frame, which keeps the
-- per-frame cost proportional to what is actually on screen rather than to how much scenery
-- exists in total.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local MAP_NAME = "ObbyMap"
local connections = {}
local cleanups = {}  -- one per tag: puts that tag's parts back and drops its entries

-- The obby's own parts only. Checked as each part arrives, so a map cloned in after this script
-- started is picked up as it streams in.
local function inMap(inst)
	local map = Workspace:FindFirstChild(MAP_NAME)
	return map ~= nil and inst:IsDescendantOf(map)
end

local FAR_DISTANCE = 190        -- past this, nothing animates
local FAR_SQ = FAR_DISTANCE * FAR_DISTANCE

----------------------------------------------------------------
-- Tag bookkeeping: one array per tag, kept in step with the world.
----------------------------------------------------------------
local function track(tagName, onAdd, onRemove)
	local list = {}
	local index = {}

	local function add(inst)
		if not inst:IsA("BasePart") or index[inst] or not inMap(inst) then
			return
		end
		local entry = onAdd and onAdd(inst) or {part = inst}
		entry.part = inst
		list[#list + 1] = entry
		index[inst] = entry
	end

	local function remove(inst)
		local entry = index[inst]
		if not entry then
			return
		end
		index[inst] = nil
		for i, e in ipairs(list) do
			if e == entry then
				table.remove(list, i)
				break
			end
		end
		if onRemove then
			onRemove(entry)
		end
	end

	for _, inst in ipairs(CollectionService:GetTagged(tagName)) do
		add(inst)
	end
	table.insert(connections, CollectionService:GetInstanceAddedSignal(tagName):Connect(add))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(tagName):Connect(remove))
	table.insert(cleanups, function()
		for _, entry in ipairs(list) do
			if onRemove then
				onRemove(entry)
			end
		end
		table.clear(list)
		table.clear(index)
	end)
	return list
end

----------------------------------------------------------------
-- Spin
----------------------------------------------------------------
local spinners = track("BackdropSpin", function(p)
	-- The rest CFrame is captured once. Accumulating a rotation onto the live CFrame drifts
	-- and skews the part over a few minutes of floating-point error; rebuilding from a fixed
	-- base every frame cannot.
	return {base = p.CFrame, speed = p:GetAttribute("SpinSpeed") or 0.6}
end, function(entry)
	-- back to rest (the arcade: the view can exit while the map is still standing)
	if entry.part.Parent then
		entry.part.CFrame = entry.base
	end
end)

----------------------------------------------------------------
-- Flicker
----------------------------------------------------------------
local flickers = track("BackdropFlicker", function(p)
	return {
		baseT = p.Transparency,
		fast = p:GetAttribute("FlickerFast") == true,
		seed = math.random() * 100,          -- so they do not pulse in unison
		light = p:FindFirstChildOfClass("PointLight"),
		baseB = (p:FindFirstChildOfClass("PointLight") or {}).Brightness,
	}
end, function(entry)
	if entry.part.Parent then
		entry.part.Transparency = entry.baseT
	end
	if entry.light and entry.baseB and entry.light.Parent then
		entry.light.Brightness = entry.baseB
	end
end)

----------------------------------------------------------------
-- Particles. Built on the CLIENT, so the server never replicates them.
----------------------------------------------------------------
local function steamEmitter(parent)
	local e = Instance.new("ParticleEmitter")
	e.Name = "BackdropSteamFx"
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.Color = ColorSequence.new(Color3.fromRGB(196, 186, 172), Color3.fromRGB(120, 112, 104))
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.18, 0.62),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(1, 11),
	})
	e.Lifetime = NumberRange.new(2.6, 4.2)
	e.Rate = 2.5                      -- deliberately low: haze, not a smoke screen
	e.Speed = NumberRange.new(3, 6)
	e.SpreadAngle = Vector2.new(14, 14)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-22, 22)
	e.LightEmission = 0.12
	e.Acceleration = Vector3.new(0.6, 2.2, 0)
	e.Parent = parent
	return e
end

local function emberEmitter(parent)
	local e = Instance.new("ParticleEmitter")
	e.Name = "BackdropEmberFx"
	e.Color = ColorSequence.new(Color3.fromRGB(255, 170, 70), Color3.fromRGB(190, 48, 20))
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Lifetime = NumberRange.new(2.2, 4.0)
	e.Rate = 7
	e.Speed = NumberRange.new(9, 15)
	e.SpreadAngle = Vector2.new(26, 26)
	e.LightEmission = 1
	e.Acceleration = Vector3.new(0, 3, 0)
	e.Parent = parent
	return e
end

track("BackdropSteam", function(p)
	return {emitter = steamEmitter(p)}
end, function(entry)
	if entry.emitter then
		entry.emitter:Destroy()
	end
end)

track("BackdropEmber", function(p)
	return {emitter = emberEmitter(p)}
end, function(entry)
	if entry.emitter then
		entry.emitter:Destroy()
	end
end)

----------------------------------------------------------------
-- The one loop
----------------------------------------------------------------
local function viewerPosition()
	local cam = Workspace.CurrentCamera
	if cam then
		return cam.CFrame.Position
	end
	local ch = player.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	return hrp and hrp.Position or Vector3.zero
end

local t = 0
table.insert(connections, RunService.RenderStepped:Connect(function(dt)
	t += dt
	local eye = viewerPosition()

	for _, s in ipairs(spinners) do
		local p = s.part
		if p.Parent then
			if (p.Position - eye).Magnitude <= FAR_DISTANCE then
				-- A Cylinder's face is its X, so these wheels read as turning only when the
				-- rotation is about X. Rebuilt from the captured base, never accumulated.
				p.CFrame = s.base * CFrame.Angles(t * s.speed, 0, 0)
			end
		end
	end

	for _, f in ipairs(flickers) do
		local p = f.part
		if p.Parent and (p.Position - eye).Magnitude <= FAR_DISTANCE then
			local n
			if f.fast then
				-- electric: fast, jumpy, occasionally almost out
				n = math.noise(t * 7 + f.seed, f.seed) * 0.5 + math.noise(t * 23 + f.seed, 0) * 0.5
			else
				-- gas: a slow, shallow gutter
				n = math.noise(t * 1.6 + f.seed, f.seed)
			end
			-- BIASED UPWARD, NOT CENTRED. Every emissive part here sits at Transparency 0,
			-- so a symmetric wobble spends half its time clamped at 0 and the lamp reads as
			-- dead steady. Shifting the noise into 0..1 makes the flicker a dimming from
			-- full brightness, which is also what a real gas flame does.
			local amp = f.fast and 0.34 or 0.14
			p.Transparency = math.clamp(f.baseT + (n + 0.5) * amp, 0, 1)
			if f.light and f.baseB then
				f.light.Brightness = math.max(0, f.baseB * (1 + n * (f.fast and 0.5 or 0.22)))
			end
		end
	end
end))

-- Reported LATE on purpose. This script starts before the backdrop has finished replicating,
-- so counting at load prints "0 spinning, 0 flickering" every time and reads like the tags
-- are broken when they are simply not here yet -- GetInstanceAddedSignal picks them up as
-- they stream in. Two seconds in, the number means something.
task.delay(2, function()
	if #connections == 0 then
		return -- exited already
	end
	print(("[BackdropFx] %d spinning, %d flickering, %d steam, %d ember")
		:format(#spinners, #flickers,
			#CollectionService:GetTagged("BackdropSteam"),
			#CollectionService:GetTagged("BackdropEmber")))
end)

-- Views.PlayerView sets Exiting on this copy before destroying it.
script:GetAttributeChangedSignal("Exiting"):Connect(function()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	for _, cleanup in ipairs(cleanups) do
		cleanup()
	end
	table.clear(cleanups)
end)
