-- ReplicatedStorage.Obby.Views.Player.DarkRoom (LocalScript template; Views.PlayerView clones it into
-- PlayerGui for the runner only). New in the arcade.
--
-- WHY THIS EXISTS. In the standalone obby the dark room (bay 4) dimmed the whole game through Lighting.
-- In the arcade Lighting belongs to the arcade: the Workshop, the other bays' games and the robot
-- operator's overseer view all share it, so dimming it would black out every one of them -- including
-- the operator, whose whole job in that bay is to see what the runner cannot. So the darkness moved to
-- the one screen it is for: HazardManager sets the attribute Dark = true on the bay model instead, and
-- this script puts a ColorCorrectionEffect named "ObbyDark" under this client's own camera while the
-- character stands inside that bay, and fades it out again when they leave. The sconces are PointLights,
-- so they still read; the screws stay hidden by the bay's own lighting logic regardless.
--
-- INSIDE means the bay's footprint: X 0..Config.BayWidth, Z from the bay's entrance edge
-- (RunControl.bayZStart: Config.OriginZ + (n - 1) * Config.BayPitch) to + Config.BayDepth, any Y. The
-- catwalks between bays are outside, so the dark starts at the door. Tunables: Config.DarkTint,
-- DarkBrightness, DarkContrast, DarkSaturation.
--
-- On the copy's Exiting attribute (Views.PlayerView) it disconnects and destroys the effect at once;
-- PlayerView also removes any "ObbyDark" left under the camera.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))

local player = Players.LocalPlayer

local MAP_NAME = "ObbyMap"
local EFFECT_NAME = "ObbyDark"
local CHECK_EVERY = 0.1
local FADE = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local NEUTRAL = {
	TintColor = Color3.new(1, 1, 1),
	Brightness = 0,
	Contrast = 0,
	Saturation = 0,
}
local DARK = {
	TintColor = Config.DarkTint,
	Brightness = Config.DarkBrightness,
	Contrast = Config.DarkContrast,
	Saturation = Config.DarkSaturation,
}

local connections = {}
local effect = nil   -- the ColorCorrectionEffect while there is one
local tween = nil
local dark = false

-- The bay model the position stands in, if that bay is dark right now.
local function darkBayAt(pos)
	local map = workspace:FindFirstChild(MAP_NAME)
	local warehouse = map and map:FindFirstChild("Warehouse")
	if not warehouse or pos.X < 0 or pos.X > Config.BayWidth then
		return nil
	end
	local n = math.floor((pos.Z - Config.OriginZ) / Config.BayPitch) + 1
	if n < 1 or n > Config.NumBays then
		return nil
	end
	local zStart = Config.OriginZ + (n - 1) * Config.BayPitch
	if pos.Z < zStart or pos.Z > zStart + Config.BayDepth then
		return nil -- on the catwalk past this bay's far edge
	end
	local bay = warehouse:FindFirstChild(("Bay%02d"):format(n))
	if bay and bay:GetAttribute("Dark") == true then
		return bay
	end
	return nil
end

local function play(target, props, onDone)
	if tween then
		tween:Cancel()
	end
	tween = TweenService:Create(target, FADE, props)
	if onDone then
		local mine = tween
		mine.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and tween == mine then
				onDone()
			end
		end)
	end
	tween:Play()
end

local function setDark(on)
	local camera = workspace.CurrentCamera
	if on then
		-- (re)made whenever it is missing: a new CurrentCamera, or PlayerView's sweep
		if not (effect and effect.Parent == camera) then
			if effect then
				effect:Destroy()
			end
			effect = camera and camera:FindFirstChild(EFFECT_NAME)
			if not effect then
				effect = Instance.new("ColorCorrectionEffect")
				effect.Name = EFFECT_NAME
				for k, v in pairs(NEUTRAL) do
					effect[k] = v
				end
				effect.Parent = camera
			end
			dark = false
		end
		if not dark then
			dark = true
			play(effect, DARK)
		end
	elseif dark then -- (not dark: already neutral, or already fading out)
		dark = false
		local fading = effect
		if fading then
			play(fading, NEUTRAL, function()
				if not dark and effect == fading then
					fading:Destroy()
					effect = nil
				end
			end)
		end
	end
end

local since = 0
table.insert(connections, RunService.Heartbeat:Connect(function(dt)
	since += dt
	if since < CHECK_EVERY then
		return
	end
	since = 0
	local ch = player.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	setDark(hrp ~= nil and darkBayAt(hrp.Position) ~= nil)
end))

-- Views.PlayerView sets Exiting on this copy before destroying it.
script:GetAttributeChangedSignal("Exiting"):Connect(function()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if tween then
		tween:Cancel()
		tween = nil
	end
	if effect then
		effect:Destroy()
		effect = nil
	end
	dark = false
end)
