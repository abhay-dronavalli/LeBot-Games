-- ReplicatedStorage.Core.Views.LobbyRobotView
-- The robot station while no game is active: a slow orbit over the room (Core.Config.lobbyOrbit), a big
-- "ROBOT STATION" title, "Waiting for your partner to pick a game", and the robot link badge from the
-- "RobotLink" attribute on ReplicatedStorage.Core (set by Core.StateStore on the server: "live", "mock",
-- "offline" or "fake"), so the operator can see the arm is connected before a game starts.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Core = ReplicatedStorage:WaitForChild("Core")
local Config = require(Core:WaitForChild("Config"))

local BADGES = {
	live = { "ROBOT LIVE", Color3.fromRGB(46, 160, 82) },
	mock = { "MOCK", Color3.fromRGB(70, 110, 200) },
	offline = { "OFFLINE", Color3.fromRGB(200, 60, 50) },
	fake = { "NO ROBOT", Color3.fromRGB(96, 96, 108) },
}

local LobbyRobotView = {}

local gui, connections = nil, {}

local function label(parent, name, text, size, props)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.new(1, 1, 1)
	l.Font = Enum.Font.GothamBlack
	l.TextSize = size
	l.TextWrapped = true
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = l
	return l
end

function LobbyRobotView.enter()
	LobbyRobotView.exit()
	gui = Instance.new("ScreenGui")
	gui.Name = "RobotStation"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10

	label(gui, "Title", "ROBOT STATION", 64, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.new(1, -40, 0, 80) })
	label(gui, "Waiting", "Waiting for your partner to pick a game", 26, { Font = Enum.Font.GothamBold,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.new(1, -40, 0, 36) })
	local badge = label(gui, "RobotBadge", "", 22, { Font = Enum.Font.GothamBold, BackgroundTransparency = 0,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.62), Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false })
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 20)
	corner.Parent = badge
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 18), UDim.new(0, 18)
	pad.Parent = badge
	local function showBadge()
		local b = BADGES[Core:GetAttribute("RobotLink")] or BADGES.offline
		badge.Text, badge.BackgroundColor3 = b[1], b[2]
	end
	showBadge()
	table.insert(connections, Core:GetAttributeChangedSignal("RobotLink"):Connect(showBadge))
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local orbit = Config.lobbyOrbit
	-- A game's view may have left a depth of field effect in Lighting (local to this client): keep the
	-- room in focus around the orbit's center instead of whatever blur it had.
	local focus = {}
	for _, effect in ipairs(Lighting:GetChildren()) do
		if effect:IsA("DepthOfFieldEffect") then
			table.insert(focus, effect)
		end
	end
	local started = os.clock()
	table.insert(connections, RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Scriptable
		local a = (os.clock() - started) / orbit.seconds * 2 * math.pi
		local eye = orbit.center + Vector3.new(math.cos(a) * orbit.radius, orbit.height, math.sin(a) * orbit.radius)
		camera.CFrame = CFrame.lookAt(eye, orbit.center)
		for _, effect in ipairs(focus) do
			effect.FocusDistance = (eye - orbit.center).Magnitude
			effect.InFocusRadius = 30
			effect.FarIntensity = 0.18
			effect.NearIntensity = 0
		end
	end))
end

function LobbyRobotView.exit()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if gui then
		gui:Destroy()
		gui = nil
	end
end

return LobbyRobotView
