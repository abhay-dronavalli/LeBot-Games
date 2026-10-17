-- StarterGui.PatternHud.HudClient
-- Plain Pattern Match HUD: state, round, time left, score and message from the PatternUI remote.
-- No styling yet (build step 9).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch:WaitForChild("Config"))
local patternUI = PatternMatch:WaitForChild("Remotes"):WaitForChild("PatternUI")

local screen = script.Parent

local frame = Instance.new("Frame")
frame.Name = "Panel"
frame.AnchorPoint = Vector2.new(0.5, 0)
frame.Position = UDim2.new(0.5, 0, 0, 8)
frame.Size = UDim2.new(1, -32, 0, 140)
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
local scoreLabel = line("Score", 3, 24, 18)
local messageLabel = line("Message", 4, 52, 20)

patternUI.OnClientEvent:Connect(function(p)
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

	local rounds = {}
	for r, points in ipairs(p.roundScores or {}) do
		table.insert(rounds, string.format("R%d %d", r, points))
	end
	scoreLabel.Text = string.format("Score %d", p.score or 0) .. (#rounds > 0 and ("   (" .. table.concat(rounds, ", ") .. ")") or "")

	messageLabel.Text = p.message or ""
end)
