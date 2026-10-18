-- Edit-time lighting setup for the Pattern Match bedroom. Not part of the game: run it in Studio's
-- command bar (or via the MCP execute_luau tool) after build_room.lua and build_pattern_cabinet.lua.
-- Re-runnable. Undo with Ctrl+Z.
--   - LightingStyle Realistic, GlobalShadows on.
--   - Warm late-afternoon sun low in the west (-X) so it streams through the bedroom window
--     (Room.Window, on the -X wall) onto the rug and the TargetBoard.
--   - Slightly cool indoor ambient, so shade reads cool against the warm sun and lamps, and the purple /
--     blue LED strips around the ceiling and desk glow through a mild Bloom.
--   - A warm downward SpotLight in the ceiling lamp over the table, so both boards stay bright and readable.
--   - Lighting.CabinetFocus, the DepthOfFieldEffect that StarterPlayerScripts.CabinetFocus drives every
--     frame (its values here are only the starting point).
-- Lighting.Technology isn't scriptable from here: set it to Future by hand in the Properties panel.

local Lighting = game:GetService("Lighting")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local recording = ChangeHistoryService:TryBeginRecording("Setup Pattern Match lighting")
local notes = {}

local styleOk = pcall(function() Lighting.LightingStyle = Enum.LightingStyle.Realistic end)
table.insert(notes, "LightingStyle " .. (styleOk and "Realistic" or "NOT set"))
pcall(function() Lighting.PrioritizeLightingQuality = true end)
Lighting.GlobalShadows = true
Lighting.GeographicLatitude = 30
Lighting.ClockTime = 16.3                                   -- sun ~25 deg up, from -X: through the window
Lighting.Brightness = 3
Lighting.ColorShift_Top = Color3.fromRGB(255, 214, 170)     -- sunlit faces: warm late-afternoon light
Lighting.ColorShift_Bottom = Color3.fromRGB(0, 0, 0)
Lighting.Ambient = Color3.fromRGB(112, 112, 138)            -- indoor shade: a touch cool / violet
Lighting.OutdoorAmbient = Color3.fromRGB(128, 132, 150)
Lighting.ShadowSoftness = 0.45
Lighting.EnvironmentDiffuseScale = 0.6
Lighting.EnvironmentSpecularScale = 0.35
Lighting.ExposureCompensation = 0.25

local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
if atmosphere then
	atmosphere.Density = 0.2   -- light haze on the sky outside the window, none to speak of indoors
	atmosphere.Offset = 0
	atmosphere.Haze = 0
	atmosphere.Glare = 0
end
local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
if bloom then
	bloom.Enabled = true
	bloom.Intensity = 0.6      -- enough for the Neon LED strips and monitors to glow
	bloom.Size = 28
	bloom.Threshold = 1.4
end
local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect")
if sunRays then
	sunRays.Intensity = 0.04
	sunRays.Spread = 0.3
end

-- Depth of field: one effect, driven per client by StarterPlayerScripts.CabinetFocus.
for _, effect in ipairs(Lighting:GetChildren()) do
	if effect:IsA("DepthOfFieldEffect") and effect.Name ~= "CabinetFocus" then
		effect:Destroy()
	end
end
local focus = Lighting:FindFirstChild("CabinetFocus") or Instance.new("DepthOfFieldEffect")
focus.Name = "CabinetFocus"
focus.Enabled = true
focus.FocusDistance = 28
focus.InFocusRadius = 24
focus.FarIntensity = 0.18
focus.NearIntensity = 0
focus.Parent = Lighting

-- Key light over the table: a warm SpotLight pointing down from the ceiling lamp.
local lamp = workspace:FindFirstChild("Room") and workspace.Room:FindFirstChild("Lights")
	and workspace.Room.Lights:FindFirstChild("CeilingLamp")
if lamp then
	local spot = lamp:FindFirstChild("TableKey") or Instance.new("SpotLight")
	spot.Name = "TableKey"
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 95
	spot.Range = 40
	spot.Brightness = 2.2
	spot.Color = Color3.fromRGB(255, 232, 205)
	spot.Shadows = true
	spot.Parent = lamp
	local point = lamp:FindFirstChildOfClass("PointLight")
	if point then
		point.Brightness = 0.8   -- general room fill; the SpotLight does the table
	end
	table.insert(notes, "table key light on " .. lamp:GetFullName())
else
	table.insert(notes, "no Room.Lights.CeilingLamp; table key light skipped (run build_room.lua first)")
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end
local sun = Lighting:GetSunDirection()
table.insert(notes, string.format("sun direction (%.2f, %.2f, %.2f)", sun.X, sun.Y, sun.Z))
return table.concat(notes, "; ")
