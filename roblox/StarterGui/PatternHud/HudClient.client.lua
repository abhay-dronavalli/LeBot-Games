-- StarterGui.PatternHud.HudClient
-- Plain Pattern Match HUD: state, round, time left, score and message from the PatternUI remote,
-- plus the event banner. While a Tremor is active this client shakes its camera and the boards
-- (PatternMatch.BoardShake, restored exactly afterwards). Hidden while this player is on the mode
-- select screen. No styling yet (build step 9).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch:WaitForChild("Config"))
local BoardShake = require(PatternMatch:WaitForChild("BoardShake"))
local patternUI = PatternMatch:WaitForChild("Remotes"):WaitForChild("PatternUI")
local cabinet = workspace:WaitForChild("PatternCabinet")
local localPlayer = Players.LocalPlayer

local CAMERA_SHAKE_STUDS = 0.12
local CAMERA_SHAKE_RADIANS = math.rad(0.6)

local screen = script.Parent

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(0.5, 0)
frame.Position = UDim2.new(0.5, 0, 0, 8)
frame.Size = UDim2.new(1, -32, 0, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y -- grows with the visible lines
frame.BackgroundColor3 = Color3.new(0, 0, 0)
frame.BackgroundTransparency = 0.35
frame.Parent = screen

local maxWidth = Instance.new("UISizeConstraint")
maxWidth.MaxSize = Vector2.new(520, math.huge)
maxWidth.Parent = frame

local padding = Instance.new("UIPadding")
padding.PaddingLeft, padding.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
padding.PaddingTop, padding.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6)
padding.Parent = frame

local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local function line(name, order, height, textSize)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, height)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = textSize
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = ""
	label.Parent = frame
	return label
end

local stateLabel = line("State", 1, 28, 22)
local roundLabel = line("Round", 2, 24, 18)
local revealLabel = line("Reveal", 3, 24, 18) -- Hard mode only
local eventLabel = line("Event", 4, 30, 24)   -- only while an event is warning or active
local scoreLabel = line("Score", 5, 24, 18)
local messageLabel = line("Message", 6, 52, 20)
revealLabel.Font = Enum.Font.GothamBold
revealLabel.Visible = false
eventLabel.Font = Enum.Font.GothamBold
eventLabel.TextColor3 = Color3.fromRGB(255, 210, 60)
eventLabel.Visible = false

-- Tremor: nudge the camera a little every frame (after the camera scripts have placed it) and shake
-- both boards locally.
local shaking = false
local boardShake = nil
local function setTremor(on)
	if on == shaking then
		return
	end
	shaking = on
	if on then
		local rng = Random.new()
		RunService:BindToRenderStep("PatternTremor", Enum.RenderPriority.Camera.Value + 1, function()
			local camera = workspace.CurrentCamera
			camera.CFrame *= CFrame.new(rng:NextNumber(-CAMERA_SHAKE_STUDS, CAMERA_SHAKE_STUDS),
				rng:NextNumber(-CAMERA_SHAKE_STUDS, CAMERA_SHAKE_STUDS), 0)
				* CFrame.Angles(0, 0, rng:NextNumber(-CAMERA_SHAKE_RADIANS, CAMERA_SHAKE_RADIANS))
		end)
		boardShake = BoardShake.start({ cabinet:WaitForChild("TargetBoard"), cabinet:WaitForChild("LiveBoard") })
	else
		RunService:UnbindFromRenderStep("PatternTremor")
		if boardShake then
			boardShake:stop()
			boardShake = nil
		end
	end
end

patternUI.OnClientEvent:Connect(function(p)
	-- The mode select screen replaces the HUD for the player who is choosing.
	frame.Visible = not (p.state == "ModeSelect" and p.chooserUserId == localPlayer.UserId)
	stateLabel.Text = "Pattern Match: " .. p.state

	local round = ""
	if p.mode then
		round = p.mode .. " mode"
	end
	if p.round and p.round > 0 and p.state ~= "Idle" then
		round ..= string.format("   Round %d of %d", p.round, #Config.blocksPerRound)
	end
	if p.timeLeft and p.timeLeft > 0 then
		round ..= string.format("   %d s left", p.timeLeft)
	end
	roundLabel.Text = round

	revealLabel.Visible = p.revealPhase ~= nil
	if p.revealPhase then
		revealLabel.Text = string.format("COLORS %s %ds", p.revealPhase == "show" and "VISIBLE" or "HIDDEN", p.revealTimeLeft or 0)
	end

	local event = p.event
	eventLabel.Visible = event ~= nil
	if event then
		if event.phase == "warning" then
			eventLabel.Text = string.format("WARNING: %s in %ds", event.banner, event.timeLeft)
		else
			eventLabel.Text = string.format("%s  %ds", event.banner, event.timeLeft)
		end
	end
	setTremor(event ~= nil and event.name == "tremor" and event.phase == "active")

	local rounds = {}
	for r, points in ipairs(p.roundScores or {}) do
		table.insert(rounds, string.format("R%d %d", r, points))
	end
	scoreLabel.Text = string.format("Score %d", p.score or 0) .. (#rounds > 0 and ("   (" .. table.concat(rounds, ", ") .. ")") or "")

	messageLabel.Text = p.message or ""
end)
