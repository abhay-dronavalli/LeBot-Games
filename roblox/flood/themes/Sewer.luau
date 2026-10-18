-- Studio location: ReplicatedStorage.Flood.Themes.Sewer (ModuleScript)
--[[
	Sewer theme, client side. FloodClient calls:
	  Sewer.bind(arena, api)    when the sewer map appears (api.showBanner)
	  Sewer.update(dt, info)    every frame while the map exists
	  Sewer.unbind()            when the map is removed
	Lighting and ambient sounds only apply while the local player is inside the chamber,
	and are restored exactly when they leave or the round ends.
]]

local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local Sewer = {}

local arena, settings
local scrolls, falls, junk, flickers, rats, ducks, sounds3d = {}, {}, {}, {}, {}, {}, {}
local timerLabel
local savedLighting
local ambient
local wasInSludge = false
local nextRatAt = 0
local duckCooldown = 0
local t = 0
local rng = Random.new()

local function attr(name, default)
	local v = settings and settings:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

------------------------------------------------------------------ lighting

local function lightingTargets()
	return {
		{ Lighting, "ClockTime", attr("L_ClockTime", 14) },
		{ Lighting, "Brightness", attr("L_Brightness", 1) },
		{ Lighting, "Ambient", attr("L_Ambient", Color3.fromRGB(40, 50, 35)) },
		{ Lighting, "OutdoorAmbient", attr("L_OutdoorAmbient", Color3.fromRGB(60, 75, 55)) },
		{ Lighting:FindFirstChildOfClass("Atmosphere"), "Density", attr("A_Density", 0.4) },
		{ Lighting:FindFirstChildOfClass("Atmosphere"), "Offset", attr("A_Offset", 0.15) },
		{ Lighting:FindFirstChildOfClass("Atmosphere"), "Haze", attr("A_Haze", 1.5) },
		{ Lighting:FindFirstChildOfClass("Atmosphere"), "Color", attr("A_Color", Color3.fromRGB(150, 190, 110)) },
		{ Lighting:FindFirstChildOfClass("Atmosphere"), "Decay", attr("A_Decay", Color3.fromRGB(60, 80, 50)) },
		{ Lighting:FindFirstChild("ColorCorrection"), "TintColor", attr("CC_Tint", Color3.fromRGB(235, 255, 225)) },
		{ Lighting:FindFirstChild("ColorCorrection"), "Contrast", attr("CC_Contrast", 0.08) },
		{ Lighting:FindFirstChild("ColorCorrection"), "Saturation", attr("CC_Saturation", 0.1) },
		{ Lighting:FindFirstChildOfClass("BloomEffect"), "Intensity", attr("B_Intensity", 0.4) },
		{ Lighting:FindFirstChildOfClass("BloomEffect"), "Size", attr("B_Size", 24) },
		{ Lighting:FindFirstChildOfClass("BloomEffect"), "Threshold", attr("B_Threshold", 1.3) },
	}
end

local function applyLighting()
	if savedLighting then
		return
	end
	savedLighting = {}
	for _, e in lightingTargets() do
		local obj, prop, value = e[1], e[2], e[3]
		if obj then
			table.insert(savedLighting, { obj, prop, obj[prop] })
			obj[prop] = value
		end
	end
	if ambient then
		ambient:Play()
	end
	for _, s in sounds3d do
		s:Play()
	end
end

local function restoreLighting()
	if not savedLighting then
		return
	end
	for _, e in savedLighting do
		if e[1].Parent then
			e[1][e[2]] = e[3]
		end
	end
	savedLighting = nil
	if ambient then
		ambient:Stop()
	end
	for _, s in sounds3d do
		s:Stop()
	end
end

------------------------------------------------------------------ bind / unbind

function Sewer.bind(a, api)
	arena = a
	settings = a:FindFirstChild("Settings")
	scrolls, falls, junk, flickers, rats, ducks, sounds3d = {}, {}, {}, {}, {}, {}, {}
	for _, d in a:GetDescendants() do
		if d:IsA("Texture") and d.Name == "ScrollTexture" then
			table.insert(scrolls, d)
		elseif d:IsA("BasePart") and d.Name == "SlimeFall" then
			table.insert(falls, { part = d, topY = d.Position.Y + d.Size.Y / 2, splash = d:FindFirstChild("SplashPoint") })
		elseif d:IsA("BasePart") and d.Name == "Bulb" and d:GetAttribute("Flicker") then
			table.insert(flickers, { bulb = d, light = d:FindFirstChildOfClass("PointLight"), base = 1.2, nextAt = 0 })
		elseif d:IsA("Sound") and (d.Name == "Gush" or d.Name == "Bubbling") then
			table.insert(sounds3d, d)
		end
	end
	local floor = a:FindFirstChild("Floor")
	local floorY = floor.Position.Y + floor.Size.Y / 2
	local junkFolder = a:FindFirstChild("Junk")
	if junkFolder then
		for _, m in junkFolder:GetChildren() do
			if m:IsA("Model") and m.PrimaryPart then
				local pivot = m:GetPivot()
				local entry = {
					model = m,
					offset = pivot.Position.Y - floorY, -- how high it rides above the sludge
					x = pivot.Position.X,
					z = pivot.Position.Z,
					rot = pivot - pivot.Position,
					yaw = 0,
					phase = rng:NextNumber(0, math.pi * 2),
					dir = rng:NextUnitVector() * Vector3.new(1, 0, 1),
					spin = rng:NextNumber(-0.3, 0.3),
				}
				table.insert(junk, entry)
				if m:GetAttribute("Kind") == "Duck" then
					table.insert(ducks, entry)
				end
			end
		end
	end
	local props = a:FindFirstChild("Props")
	if props then
		for _, m in props:GetChildren() do
			if m:GetAttribute("Kind") == "Rat" and m.PrimaryPart then
				table.insert(rats, { model = m, home = m:GetPivot(), phase = rng:NextNumber(0, 6) })
			end
		end
	end
	local signs = a:FindFirstChild("Signs")
	local readout = signs and signs:FindFirstChild("TimerReadout")
	timerLabel = readout and readout:FindFirstChild("SurfaceGui") and readout.SurfaceGui:FindFirstChild("Digits")

	ambient = Instance.new("Sound")
	ambient.Name = "SewerAmbient"
	ambient.SoundId = attr("Sound_Ambient", "")
	ambient.Looped = true
	ambient.Volume = 0.4
	ambient.PlaybackSpeed = 0.85
	ambient.Parent = SoundService

	nextRatAt = os.clock() + rng:NextNumber(attr("RatSqueakMin", 8), attr("RatSqueakMax", 15))
	wasInSludge = false
	if api and api.showBanner then
		api.showBanner(attr("IntroText", "SEWER FLOOD"), Color3.fromRGB(150, 255, 90), 3)
	end
end

function Sewer.unbind()
	restoreLighting()
	if ambient then
		ambient:Destroy()
		ambient = nil
	end
	arena, settings, timerLabel = nil, nil, nil
	scrolls, falls, junk, flickers, rats, ducks, sounds3d = {}, {}, {}, {}, {}, {}, {}
end

------------------------------------------------------------------ effects

local function splash(pos)
	local p = Instance.new("Part")
	p.Name = "SludgeSplash"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.new(pos)
	p.Parent = workspace
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color = ColorSequence.new(Color3.fromRGB(170, 240, 80))
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 2.4) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.5, 0.8)
	pe.Speed = NumberRange.new(10, 18)
	pe.SpreadAngle = Vector2.new(50, 50)
	pe.Acceleration = Vector3.new(0, -60, 0)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Rate = 0
	pe.Parent = p
	pe:Emit(30)
	local s = Instance.new("Sound")
	s.SoundId = attr("Sound_Splat", "")
	s.Volume = 0.8
	s.Parent = p
	s:Play()
	Debris:AddItem(p, 2)
end

-- info = { inside, level, floorY, timeLeft, roundTime, state, hrp, hum }
function Sewer.update(dt, info)
	if not arena then
		return
	end
	t += dt
	if info.inside then
		applyLighting()
	else
		restoreLighting()
		return -- nobody local is watching; skip the per-frame visuals
	end

	local surfaceY = info.floorY + math.max(info.level, 0.3)

	-- churning textures and slime falls
	for _, tex in scrolls do
		tex.OffsetStudsU = (tex.OffsetStudsU + (tex:GetAttribute("ScrollU") or 0) * dt) % 100
		tex.OffsetStudsV = (tex.OffsetStudsV + (tex:GetAttribute("ScrollV") or 0) * dt) % 100
	end
	for _, f in falls do
		local bottom = math.min(surfaceY, f.topY - 0.5)
		local h = f.topY - bottom
		local p = f.part
		p.Size = Vector3.new(p.Size.X, h, p.Size.Z)
		p.CFrame = CFrame.new(p.Position.X, bottom + h / 2, p.Position.Z)
		if f.splash then
			f.splash.Position = Vector3.new(0, -h / 2, 0)
		end
	end

	-- junk bobs on the surface, drifts slowly, bounces off the walls and the tower
	local amp = attr("JunkBobAmplitude", 0.3)
	local speed = attr("JunkDriftSpeed", 0.6)
	local floor = arena:FindFirstChild("Floor")
	local cx, cz = floor.Position.X, floor.Position.Z
	for _, j in junk do
		j.x += j.dir.X * speed * dt
		j.z += j.dir.Z * speed * dt
		local dx, dz = j.x - cx, j.z - cz
		if math.abs(dx) > 30 then
			j.dir = Vector3.new(-math.sign(dx) * math.abs(j.dir.X), 0, j.dir.Z)
		end
		if math.abs(dz) > 30 then
			j.dir = Vector3.new(j.dir.X, 0, -math.sign(dz) * math.abs(j.dir.Z))
		end
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < 13 and dist > 0 then
			j.dir = Vector3.new(dx / dist, 0, dz / dist)
		end
		j.yaw += j.spin * dt
		local bob = math.sin(t * 1.6 + j.phase) * amp
		local tilt = math.sin(t * 1.1 + j.phase) * 0.06
		j.model:PivotTo(CFrame.new(j.x, surfaceY + j.offset + bob, j.z) * CFrame.Angles(tilt, j.yaw, tilt * 0.5) * j.rot)
	end

	-- duck squeak when the local player gets close
	if info.hrp and os.clock() > duckCooldown then
		for _, d in ducks do
			if (d.model:GetPivot().Position - info.hrp.Position).Magnitude < 5 then
				local sq = d.model.PrimaryPart:FindFirstChild("Squeak")
				if sq then
					sq.PlaybackSpeed = rng:NextNumber(0.9, 1.15)
					sq:Play()
				end
				duckCooldown = os.clock() + 1.2
				break
			end
		end
	end

	-- lantern flicker
	for _, f in flickers do
		if os.clock() > f.nextAt then
			local on = rng:NextNumber() > 0.25
			f.light.Brightness = if on then f.base * rng:NextNumber(0.6, 1.1) else 0.1
			f.bulb.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
			f.nextAt = os.clock() + rng:NextNumber(0.04, 0.35)
		end
	end

	-- rats: tiny idle bob, and a squeak every 8-15 s
	for _, r in rats do
		r.model:PivotTo(r.home * CFrame.new(0, math.abs(math.sin(t * 3 + r.phase)) * 0.12, 0) * CFrame.Angles(0, math.sin(t * 0.7 + r.phase) * 0.25, 0))
	end
	if os.clock() > nextRatAt and #rats > 0 then
		local r = rats[rng:NextInteger(1, #rats)]
		local sq = r.model.PrimaryPart:FindFirstChild("Squeak")
		if sq then
			sq.SoundId = if rng:NextNumber() > 0.5 then attr("Sound_Rat1", sq.SoundId) else attr("Sound_Rat2", sq.SoundId)
			sq:Play()
		end
		nextRatAt = os.clock() + rng:NextNumber(attr("RatSqueakMin", 8), attr("RatSqueakMax", 15))
	end

	-- timer readout follows Flood's round clock
	if timerLabel then
		local secs = if info.state == "Running" then math.ceil(info.timeLeft) elseif info.state == "Countdown" then (info.roundTime or 60) else 0
		timerLabel.Text = string.format("%02d:%02d", secs // 60, secs % 60)
	end

	-- splash + splat when the local player drops into the sludge
	if info.hrp and info.hum then
		local feet = info.hrp.Position.Y - info.hum.HipHeight - info.hrp.Size.Y / 2
		local inSludge = info.level > 0.5 and feet < surfaceY - 0.2
		if inSludge and not wasInSludge then
			splash(Vector3.new(info.hrp.Position.X, surfaceY, info.hrp.Position.Z))
		end
		wasInSludge = inSludge
	end
end

return Sewer
