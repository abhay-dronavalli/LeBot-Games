-- ReplicatedStorage.PatternMatch.Views.RobotView
-- Pattern Match for the robot role. The operator is blind by design, so this never shows the boards, the
-- target or the tickets: it gets its own payload (PatternMatch.Remotes.RobotUI, from
-- Game.robotPayload: state, timer, score, tickets done and the latest ORDER UP, nothing else), and the
-- camera is a fixed shot of the back of the room with the whole cabinet behind it, so neither the boards
-- nor anything floating above them (celebration text, attract sign) is ever in the frame.
-- The room is blurred like the mode select shot (a depth of field effect under the camera, made on enter
-- and destroyed on exit, never in Lighting: the arcade owns it; same intensities, focused right in front
-- of the camera) behind a centered card:
--   "PATTERN MATCH" / "You're the robot. You can't see the board. Listen to your partner."
--   before the shift: what the partner is doing; during it: the shift timer and the score, and a big
--   "ORDER UP! +points" flash when a ticket clears, and the win target; results: WIN or LOSE and the
--   final score.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch:WaitForChild("Config"))
local remotes = PatternMatch:WaitForChild("Remotes")

-- The shot, in the map's own frame (the arcade mode puts the map's origin at Config.mapOffset): between
-- the cabinet (z -47 at its back edge) and the back wall, looking at the gaming desk. Everything Pattern
-- Match draws is at z > -47, behind the camera.
local SHOT_FROM = Vector3.new(12, 9, -53)
local SHOT_AT = Vector3.new(16, 8, -70)
local SWAY_STUDS = 0.6
local BLUR = { FocusDistance = 0, InFocusRadius = 4, FarIntensity = 0.5, NearIntensity = 0.1 }
local FOCUS_NAME = "PatternRobotFocus"
local BAD = Color3.fromRGB(255, 90, 70)
local GOOD = Color3.fromRGB(90, 220, 120)
local FLASH_IN = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FLASH_OUT = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local RobotView = {}

local gui, focus, connections = nil, nil, {}

local function label(parent, name, text, size, props)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.new(1, 1, 1)
	l.Font = Enum.Font.GothamBold
	l.TextSize = size
	l.TextWrapped = true
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- The text under the card's title for each state of the game (payload.state).
local WAITING = {
	Idle = "Waiting for your partner to press Play",
	ModeSelect = "Your partner is picking a mode. Get ready!",
}

function RobotView.enter()
	RobotView.exit()
	gui = Instance.new("ScreenGui")
	gui.Name = "PatternRobot"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.Parent = gui

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(560, 300)
	card.BackgroundColor3 = Color3.fromRGB(20, 18, 28)
	card.BackgroundTransparency = 0.1
	card.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = card
	local scale = Instance.new("UIScale") -- fits small windows
	scale.Parent = card

	label(card, "Title", "PATTERN MATCH", 46, { Font = Enum.Font.GothamBlack, Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 52), TextColor3 = Color3.fromRGB(190, 180, 255) })
	label(card, "Line", "You're the robot. You can't see the board. Listen to your partner.", 20,
		{ Font = Enum.Font.GothamMedium, Position = UDim2.fromOffset(40, 80), Size = UDim2.new(1, -80, 0, 52),
			TextColor3 = Color3.fromRGB(220, 220, 230) })
	local status = label(card, "Status", "", 26, { Position = UDim2.fromOffset(30, 150), Size = UDim2.new(1, -60, 0, 60) })
	local timer = label(card, "Timer", "", 72, { Font = Enum.Font.GothamBlack, Position = UDim2.fromOffset(0, 140),
		Size = UDim2.new(1, 0, 0, 84), Visible = false })
	local score = label(card, "Score", "", 26, { Position = UDim2.fromOffset(0, 240), Size = UDim2.new(1, 0, 0, 40) })

	local flash = label(gui, "OrderUp", "", 96, { Font = Enum.Font.GothamBlack, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.14), Size = UDim2.new(1, -40, 0, 120), TextColor3 = GOOD, Visible = false })
	local flashStroke = Instance.new("UIStroke")
	flashStroke.Thickness = 4
	flashStroke.Parent = flash
	local flashScale = Instance.new("UIScale")
	flashScale.Parent = flash

	-- The card and the flash grow with the window, leaving room for the flash above the card.
	local function fit()
		local camera = workspace.CurrentCamera
		local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
		scale.Scale = math.clamp(math.min(viewport.X / 800, viewport.Y / 760), 0.5, 1.4)
		flash.TextSize = math.floor(96 * scale.Scale)
	end
	fit()
	table.insert(connections, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit))

	local lastOrderUp, flashToken = nil, 0
	local function update(p)
		local shift = p.state == "Shift"
		timer.Visible = shift
		timer.Text = formatTime(p.timeLeft)
		timer.TextColor3 = shift and (p.timeLeft or 0) <= 15 and BAD or Color3.new(1, 1, 1)
		if p.state == "Results" or p.state == "Done" then
			status.Text = p.won and "SHIFT OVER: WIN!" or "SHIFT OVER: LOSE"
			status.TextColor3 = p.won and GOOD or BAD
			score.Text = string.format("Final score %d   (%d to win)", p.score or 0, p.winPoints or Config.winPoints)
		elseif shift then
			status.Text = ""
			score.Text = string.format("Score %d / %d to win   Tickets %d", p.score or 0, p.winPoints or Config.winPoints,
				p.completedCount or 0)
		else
			status.Text = WAITING[p.state] or WAITING.Idle
			status.TextColor3 = Color3.new(1, 1, 1)
			score.Text = ""
		end
		local seq = p.orderUp and p.orderUp.seq
		if seq and seq ~= lastOrderUp and lastOrderUp ~= nil and shift then
			flashToken += 1
			local mine = flashToken
			flash.Text = string.format("ORDER UP! +%d", p.orderUp.points or 0)
			flash.Visible = true
			flash.TextTransparency, flashStroke.Transparency = 0, 0
			flashScale.Scale = 0.4
			TweenService:Create(flashScale, FLASH_IN, { Scale = 1 }):Play()
			task.delay(1.4, function()
				if flashToken == mine and flash.Parent then
					TweenService:Create(flash, FLASH_OUT, { TextTransparency = 1 }):Play()
					TweenService:Create(flashStroke, FLASH_OUT, { Transparency = 1 }):Play()
				end
			end)
		end
		lastOrderUp = seq or lastOrderUp or 0
	end
	update({ state = "Idle" })
	lastOrderUp = nil -- the first real payload only records the latest ORDER UP; a later one flashes
	table.insert(connections, remotes:WaitForChild("RobotUI").OnClientEvent:Connect(update))
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	remotes:WaitForChild("PatternRefresh"):FireServer() -- the current state, right away

	focus = Instance.new("DepthOfFieldEffect")
	focus.Name = FOCUS_NAME
	for k, v in pairs(BLUR) do
		focus[k] = v
	end
	focus.Parent = workspace.CurrentCamera

	local shotFrom, shotAt = Config.mapOffset + SHOT_FROM, Config.mapOffset + SHOT_AT
	local started = os.clock()
	table.insert(connections, RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if focus.Parent ~= camera then
			focus.Parent = camera
		end
		camera.CameraType = Enum.CameraType.Scriptable
		local t = os.clock() - started
		local sway = Vector3.new(math.sin(t * 0.21), math.sin(t * 0.13) * 0.5, 0) * SWAY_STUDS
		camera.CFrame = CFrame.lookAt(shotFrom + sway, shotAt)
	end))
end

function RobotView.exit()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if gui then
		gui:Destroy()
		gui = nil
	end
	if focus then
		focus:Destroy()
		focus = nil
	end
end

return RobotView
