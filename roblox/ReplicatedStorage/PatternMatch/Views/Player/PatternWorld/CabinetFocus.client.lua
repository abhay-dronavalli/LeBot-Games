-- ReplicatedStorage.PatternMatch.Views.Player.PatternWorld.CabinetFocus
-- (A template: Views.PlayerView clones it into PlayerGui for the player role and spectators; the robot
-- views set their own blur.)
-- Depth of field that keeps the Pattern Match table sharp and softly blurs the room behind it. Every
-- frame it sets Lighting.CabinetFocus (a DepthOfFieldEffect) FocusDistance to the camera's distance to
-- the table's center, with an in-focus radius wide enough for both boards and the arm twin.
-- The blur is subtle in normal play and stronger while the mode select shot is up: the mode select
-- client sets the LocalPlayer attribute "PatternShot" to true for the length of the shot.
-- Lighting changes made here are local to this client.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local NORMAL = { InFocusRadius = 24, FarIntensity = 0.18, NearIntensity = 0 }
local SHOT = { InFocusRadius = 20, FarIntensity = 0.5, NearIntensity = 0.1 }
local BLEND_RATE = 4 -- per second, toward the target settings

local localPlayer = Players.LocalPlayer
local tableTop = workspace:WaitForChild("PatternCabinet"):WaitForChild("Table"):WaitForChild("Top")

local effect = Lighting:FindFirstChild("CabinetFocus")
if not effect then
	effect = Instance.new("DepthOfFieldEffect")
	effect.Name = "CabinetFocus"
	effect.Parent = Lighting
end
effect.Enabled = true
effect.InFocusRadius = NORMAL.InFocusRadius
effect.FarIntensity = NORMAL.FarIntensity
effect.NearIntensity = NORMAL.NearIntensity

RunService.RenderStepped:Connect(function(dt)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	-- Aim a little above the table top, at the height of the blocks and the twin's lower links.
	local focusPoint = tableTop.Position + Vector3.new(0, 4, 0)
	effect.FocusDistance = math.clamp((camera.CFrame.Position - focusPoint).Magnitude, 0, 200)

	local goal = localPlayer:GetAttribute("PatternShot") == true and SHOT or NORMAL
	local k = math.min(1, dt * BLEND_RATE)
	effect.InFocusRadius += (goal.InFocusRadius - effect.InFocusRadius) * k
	effect.FarIntensity += (goal.FarIntensity - effect.FarIntensity) * k
	effect.NearIntensity += (goal.NearIntensity - effect.NearIntensity) * k
end)
