-- build/backdrop_lighting.lua -- the hall's light: warm, dim, hazy steampunk interior.
--
-- Run from the Studio command bar in EDIT mode (lighting set during a playtest is discarded,
-- and Bay 4 fights you over it at runtime):
--
--     loadstring(game:GetService("HttpService")
--         :GetAsync("http://127.0.0.1:8767/backdrop_lighting.lua"))()
--
-- Idempotent: every property is assigned, not accumulated, and the one instance it creates
-- (the ColorCorrection grade) is found by name before being created.
--
-- WHY THE BASELINE ATTRIBUTES. DarkZone's setDark() captures Ambient/OutdoorAmbient/
-- Brightness in a local when its builder runs -- so a bay reset while the room is dark
-- captures the DARK values as the baseline, and every later restore restores to black.
-- This script stamps the true baseline onto Lighting as attributes; setDark() reads them
-- back instead of trusting whatever the service happened to hold at build time.
--
-- READABILITY CONTRACT. The course floor is lit by sun through the skylight strip the hall
-- generator builds over the course (its glass has CastShadow=false). The hall floor sits
-- under a CastShadow=true roof deck, so it only gets OutdoorAmbient plus the lamps -- the
-- course reads brighter than the hall without any per-part tricks.

local Lighting = game:GetService("Lighting")

local report = {}
local function note(...)
	table.insert(report, string.format(...))
end

-- Warm dark interior ambience. OutdoorAmbient is what the roofed hall actually renders in.
Lighting.Ambient = Color3.fromRGB(92, 74, 54)
Lighting.OutdoorAmbient = Color3.fromRGB(84, 66, 48)
Lighting.Brightness = 1.2            -- the sun through the skylight; Bay 4 zeroes it at runtime
Lighting.ClockTime = 12              -- noon: the skylight shaft falls straight onto the course
Lighting.GlobalShadows = true
Lighting.ExposureCompensation = 0
-- The daytime skybox was washing the whole interior blue through image-based lighting --
-- the warm ambient never stood a chance. Indoors, the sky should contribute (almost)
-- nothing; the warmth comes from Ambient plus the lamps.
Lighting.EnvironmentDiffuseScale = 0.03
Lighting.EnvironmentSpecularScale = 0.15
-- Warm the sun itself so the skylight shaft on the course reads as gaslight, not noon.
Lighting.ColorShift_Top = Color3.fromRGB(255, 220, 178)
note("  Ambient (92,74,54), OutdoorAmbient (84,66,48), Brightness 1.2, env sky light ~off, warm sun")

-- The DarkZone restore baseline (see header).
Lighting:SetAttribute("BaselineAmbient", Lighting.Ambient)
Lighting:SetAttribute("BaselineOutdoorAmbient", Lighting.OutdoorAmbient)
Lighting:SetAttribute("BaselineBrightness", Lighting.Brightness)
note("  baseline attributes stamped for DarkZone's setDark()")

-- Haze: warm airborne soot, kept LOW. The atmosphere scatters the (blue, daytime) skybox,
-- so density is the blue-cast dial: at 0.36 the whole hall rendered cold blue. 0.18 keeps
-- depth-haze without letting the sky recolour the room. Atmosphere supersedes the legacy
-- Fog* properties entirely.
local atm = Lighting:FindFirstChildOfClass("Atmosphere")
if not atm then
	atm = Instance.new("Atmosphere")
	atm.Parent = Lighting
end
atm.Density = 0.18
atm.Offset = 0.25
atm.Color = Color3.fromRGB(196, 168, 138)
atm.Decay = Color3.fromRGB(90, 68, 52)
atm.Glare = 0
atm.Haze = 1.0
note("  Atmosphere: density 0.18, warm colour, haze 1.0")

-- Light bloom so the gas lamps and window panes halo without the course floor clipping.
local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
if not bloom then
	bloom = Instance.new("BloomEffect")
	bloom.Parent = Lighting
end
bloom.Enabled = true
bloom.Intensity = 0.8
bloom.Size = 28
bloom.Threshold = 1.35
note("  Bloom: 0.8 / size 28 / threshold 1.35")

-- Faint god-rays where the skylight shafts cross the haze.
local rays = Lighting:FindFirstChildOfClass("SunRaysEffect")
if not rays then
	rays = Instance.new("SunRaysEffect")
	rays.Parent = Lighting
end
rays.Enabled = true
rays.Intensity = 0.035
rays.Spread = 0.28
note("  SunRays: 0.035 / 0.28")

-- Subtle warm grade. Named, so re-runs find it instead of stacking a second one.
local grade = Lighting:FindFirstChild("BackdropGrade")
if not grade then
	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "BackdropGrade"
	grade.Parent = Lighting
end
grade.Enabled = true
grade.Contrast = 0.06
grade.Saturation = -0.06
grade.TintColor = Color3.fromRGB(255, 240, 222)
grade.Brightness = 0.015
note("  BackdropGrade: contrast .06, saturation -.06, warm tint")

print("[backdrop_lighting] applied:\n" .. table.concat(report, "\n"))
return table.concat(report, "\n")
