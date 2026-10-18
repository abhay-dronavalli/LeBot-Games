-- ObjectiveHud -- tells the player what the current bay actually wants from them, and how long
-- they have. Driven entirely by the server: an obstacle fires Remotes.Objective with a payload
-- when its state changes, and firing nil clears the HUD so a player outside the bay isn't being
-- told to do anything.
--
-- Payload: {title, task, hint, tone, timer, timerLabel, timerTone, flash}
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Objective = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Objective")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TONE = {
	danger = Color3.fromRGB(255, 92, 80),
	warn = Color3.fromRGB(255, 190, 70),
	ok = Color3.fromRGB(120, 240, 150),
}
local DIM = Color3.fromRGB(165, 165, 180)

local gui = Instance.new("ScreenGui")
gui.Name = "ObjectiveHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.Parent = playerGui

local root = Instance.new("Frame")
root.AnchorPoint = Vector2.new(0.5, 0)
root.Position = UDim2.new(0.5, 0, 0, 14)
root.Size = UDim2.new(0, 470, 0, 112)
root.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
root.BackgroundTransparency = 0.22
root.BorderSizePixel = 0
root.Visible = false
root.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = root

local stripe = Instance.new("Frame")
stripe.Size = UDim2.new(1, 0, 0, 3)
stripe.BorderSizePixel = 0
stripe.BackgroundColor3 = TONE.danger
stripe.Parent = root

local function line(y, height, size, colour, bold)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, -24, 0, height)
	l.Position = UDim2.new(0, 12, 0, y)
	l.BackgroundTransparency = 1
	l.TextColor3 = colour
	l.Font = bold and Enum.Font.SourceSansBold or Enum.Font.SourceSans
	l.TextSize = size
	l.TextXAlignment = Enum.TextXAlignment.Center
	l.Text = ""
	l.Parent = root
	return l
end

local titleLabel = line(10, 16, 14, DIM, true)
local taskLabel = line(28, 28, 24, TONE.danger, true)
local hintLabel = line(57, 18, 15, DIM, false)
local timerLabel = line(78, 16, 13, DIM, true)
local timerValue = line(90, 22, 20, Color3.fromRGB(255, 255, 255), true)

-- flash sits outside the panel so a transient message never shifts the layout
local flash = Instance.new("TextLabel")
flash.AnchorPoint = Vector2.new(0.5, 0)
flash.Position = UDim2.new(0.5, 0, 0, 132)
flash.Size = UDim2.new(0, 470, 0, 24)
flash.BackgroundColor3 = Color3.fromRGB(60, 20, 10)
flash.BackgroundTransparency = 0.25
flash.TextColor3 = Color3.fromRGB(255, 170, 110)
flash.Font = Enum.Font.SourceSansBold
flash.TextSize = 16
flash.BorderSizePixel = 0
flash.Text = ""
flash.Visible = false
flash.Parent = gui

local flashCorner = corner:Clone()
flashCorner.Parent = flash

Objective.OnClientEvent:Connect(function(p)
	if not p then
		root.Visible = false
		flash.Visible = false
		return
	end

	root.Visible = true
	local tone = TONE[p.tone] or TONE.danger
	stripe.BackgroundColor3 = tone
	taskLabel.TextColor3 = tone

	titleLabel.Text = p.title or ""
	taskLabel.Text = p.task or ""
	hintLabel.Text = p.hint or ""

	if p.timer then
		timerLabel.Text = p.timerLabel or ""
		-- whole seconds only; a ticking fraction reads as noise at this size
		local secs = math.max(0, math.floor(p.timer + 0.5))
		timerValue.Text = string.format("%d:%02d", math.floor(secs / 60), secs % 60)
		-- the countdown goes red on its own once it is nearly out, whatever the task tone is
		timerValue.TextColor3 = (p.timerTone and TONE[p.timerTone])
			or (secs <= 10 and TONE.danger)
			or Color3.fromRGB(255, 255, 255)
		timerLabel.Visible = true
		timerValue.Visible = true
	else
		timerLabel.Visible = false
		timerValue.Visible = false
	end

	flash.Text = p.flash or ""
	flash.Visible = (p.flash ~= nil)
end)
