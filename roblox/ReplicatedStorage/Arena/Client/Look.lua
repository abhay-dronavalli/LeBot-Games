--!strict
-- The arena's look, built on the client. Replaces the standalone mode's Arena.applyLighting.
--
-- WHY IT MOVED. In the arcade the place's Lighting belongs to the arcade: the lobby and every other
-- game share it, and a mode that rewrites Lighting when it starts leaves the lobby at midnight when
-- it stops (or races another mode doing the same). So nothing in the arena sets a Lighting property
-- or parents anything into Lighting. What can legitimately live elsewhere lives under
-- workspace.CurrentCamera, which renders post effects exactly as Lighting does but only on this
-- client: a BloomEffect and a ColorCorrectionEffect. Both are made by a view's enter() and destroyed
-- by its exit().
--
-- WHAT COULD NOT COME ACROSS. These are Lighting properties or Lighting-only children, with no
-- camera-side equivalent, so the arcade's own values apply inside the arena:
--   - Atmosphere (Density, Offset, Color, Decay, Glare, Haze) - the red-brown haze
--   - Sky (CelestialBodiesShown = false, StarCount = 0)       - the dark, empty sky
--   - ClockTime = 0                                            - night
--   - Ambient / OutdoorAmbient                                 - the warm, dim fill
--   - Brightness, ExposureCompensation                         - the overall level
--   - EnvironmentDiffuseScale / EnvironmentSpecularScale
--   - GlobalShadows
--   - Technology = Future, which the arena README asks for (set in the Properties panel, never
--     from a script). The Neon-and-Bloom look leans on it; under another technology the lava
--     still glows but the point lights read flatter.
-- The night is approximated instead with the colour grade below: pulled down, more contrast, and
-- tinted toward the arena's own OutdoorAmbient, so a daylit arcade reads as dark and lava-lit. It is
-- an approximation - shadows and sky are still the arcade's - and the numbers are GUESSES to tune in
-- Play mode against the arcade's real lighting.
--
-- WHO SEES IT. The robot view always does while the map exists. The player view is also what
-- lobby players see while the arena runs (the game is "active" for everyone), so for them the look
-- is on only while the camera is near the arena - inside its footprint plus a margin - and fades
-- rather than snaps, so walking through the LobbyTeleporter does not pop the grade on and off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Arena = ReplicatedStorage:WaitForChild("Arena")
local Theme = require(Arena:WaitForChild("Theme"))
local ArenaConfig = require(Arena:WaitForChild("ArenaConfig"))

local L = ArenaConfig.LIGHTING

local MAP_NAME = "DragonArena"

-- The night grade, on top of the style guide's own ColorCorrection values. GUESS: tune in Play.
local NIGHT_BRIGHTNESS = -0.08     -- ColorCorrection Brightness; stands in for ClockTime 0
local NIGHT_CONTRAST = 0.12        -- added to LIGHTING.Contrast; deepens the shadows Ambient lit
local NIGHT_TINT_MIX = 0.22        -- how far the tint leans from GradeTint toward OutdoorAmbient
local BLOOM_SIZE = 28              -- style guide section 4

-- How close counts as "at the arena": the arena model's own footprint plus this many studs, so a
-- camera pulled back over the lava is still inside it.
local NEAR_MARGIN = 40
local FADE_PER_S = 4               -- 1/s; about a quarter second in or out

local Look = {}

local function grade(): (number, number, number, Color3)
	return NIGHT_BRIGHTNESS,
		L.Contrast + NIGHT_CONTRAST,
		L.Saturation,
		Theme.Lighting.GradeTint:Lerp(Theme.Lighting.OutdoorAmbient, NIGHT_TINT_MIX)
end

local function make(look: any)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	-- Neon has to actually glow, or the whole brightness order collapses: the hazards stop out-
	-- ranking the dragon and the scene reads flat.
	local bloom = Instance.new("BloomEffect")
	bloom.Name = "ArenaBloom"
	bloom.Size = BLOOM_SIZE
	bloom.Threshold = L.BloomThreshold
	bloom.Intensity = 0
	bloom.Enabled = false
	bloom.Parent = camera

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "ArenaGrade"
	cc.Enabled = false
	cc.Parent = camera

	look.bloom = bloom
	look.cc = cc
end

local function unmake(look: any)
	if look.bloom then
		look.bloom:Destroy()
		look.bloom = nil
	end
	if look.cc then
		look.cc:Destroy()
		look.cc = nil
	end
end

-- Whether the camera is at the arena: 1 near it, 0 anywhere else, or with no arena at all.
local function target(look: any): number
	local map = workspace:FindFirstChild(MAP_NAME)
	if not map then
		look.footprintOf = nil
		return 0
	end
	if look.always then
		return 1
	end
	local camera = workspace.CurrentCamera
	local arenaModel = map:FindFirstChild("Arena")
	if not (camera and arenaModel and arenaModel:IsA("Model")) then
		return 0
	end
	-- The footprint is measured once per arena: GetBoundingBox walks every part, and the arena's
	-- static geometry does not move while it exists.
	if look.footprintOf ~= arenaModel then
		local box, size = arenaModel:GetBoundingBox()
		look.footprintOf = arenaModel
		look.footprintCentre = box.Position
		look.footprintRadius = math.max(size.X, size.Z) / 2 + NEAR_MARGIN
	end
	local centre = map:GetAttribute("Center")
	if typeof(centre) ~= "Vector3" then
		centre = look.footprintCentre
	end
	local at = camera.CFrame.Position
	local flat = Vector3.new(at.X - centre.X, 0, at.Z - centre.Z).Magnitude
	return flat <= look.footprintRadius and 1 or 0
end

local function step(look: any, dt: number)
	local camera = workspace.CurrentCamera
	-- The effects follow the camera if it is ever replaced, and are remade if something destroyed
	-- them along with the old one.
	if look.bloom and (look.bloom.Parent ~= camera or look.cc.Parent ~= camera) then
		unmake(look)
	end
	if not look.bloom then
		make(look)
		if not look.bloom then
			return
		end
	end

	local want = target(look)
	local k = 1 - math.exp(-FADE_PER_S * dt)
	look.weight += (want - look.weight) * k
	if math.abs(want - look.weight) < 0.01 then
		look.weight = want
	end
	local w = look.weight

	local on = w > 0
	look.bloom.Enabled = on
	look.cc.Enabled = on
	if not on then
		return
	end
	local brightness, contrast, saturation, tint = grade()
	look.bloom.Intensity = L.BloomIntensity * w
	look.cc.Brightness = brightness * w
	look.cc.Contrast = contrast * w
	look.cc.Saturation = saturation * w
	look.cc.TintColor = Color3.new(1, 1, 1):Lerp(tint, w)
end

-- Starts the look. `always` = on whenever the arena exists (the robot's view); otherwise only while
-- the camera is near it. Returns a handle for Look.stop.
function Look.start(always: boolean): any
	local look = { always = always, weight = 0, bloom = nil, cc = nil, conn = nil, footprintOf = nil,
		footprintCentre = Vector3.zero, footprintRadius = 0 }
	make(look)
	look.conn = RunService.Heartbeat:Connect(function(dt)
		step(look, dt)
	end)
	return look
end

-- Safe to call twice.
function Look.stop(look: any)
	if not look then
		return
	end
	if look.conn then
		look.conn:Disconnect()
		look.conn = nil
	end
	unmake(look)
end

return Look
