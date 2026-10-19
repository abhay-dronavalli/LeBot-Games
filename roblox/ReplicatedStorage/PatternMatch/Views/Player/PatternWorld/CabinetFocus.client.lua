-- ReplicatedStorage.PatternMatch.Views.Player.PatternWorld.CabinetFocus
-- (A template: Views.PlayerView clones it into PlayerGui for the player role and spectators; the robot
-- views set their own blur.)
-- Depth of field that keeps the Pattern Match table sharp and softly blurs the room behind it. It lives
-- under the CurrentCamera (the arcade owns Lighting, so nothing goes there): a DepthOfFieldEffect named
-- PatternMatchFocus, made when the view starts and destroyed when it exits (Exiting attribute; PlayerView
-- also removes any left over). Every frame it sets FocusDistance to the camera's distance to the table's
-- center, with an in-focus radius wide enough for both boards and the arm twin.
-- The blur is subtle in normal play and stronger while the mode select shot is up: the mode select
-- client sets the LocalPlayer attribute "PatternShot" to true for the length of the shot.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Config"))

local EFFECT_NAME = "PatternMatchFocus"
local NORMAL = { InFocusRadius = 24, FarIntensity = 0.18, NearIntensity = 0 }
local SHOT = { InFocusRadius = 20, FarIntensity = 0.5, NearIntensity = 0.1 }
local BLEND_RATE = 4 -- per second, toward the target settings

local localPlayer = Players.LocalPlayer
local tableTop = workspace:WaitForChild(Config.mapName):WaitForChild("PatternCabinet"):WaitForChild("Table")
	:WaitForChild("Top")

local effect = Instance.new("DepthOfFieldEffect")
effect.Name = EFFECT_NAME
effect.InFocusRadius = NORMAL.InFocusRadius
effect.FarIntensity = NORMAL.FarIntensity
effect.NearIntensity = NORMAL.NearIntensity

local connection = RunService.RenderStepped:Connect(function(dt)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if effect.Parent ~= camera then
		effect.Parent = camera -- (again, if the CurrentCamera was replaced)
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

script.Parent:GetAttributeChangedSignal("Exiting"):Connect(function()
	connection:Disconnect()
	effect:Destroy()
end)
