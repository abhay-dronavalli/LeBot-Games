-- ObjectiveHud -- what the bay wants, how long you have, and anything that just happened.
--
-- Driven entirely by the server: an obstacle fires Remotes.Objective with a payload when its
-- state changes, and firing nil clears the HUD so a player outside the bay isn't being told to
-- do anything.
--
-- Payload: {title, task, hint, tone, timer, timerLabel, timerTone, flash, steps, note}
--
-- THREE LAYERS, deliberately separated, because they answer different questions and used to
-- be crammed into one panel:
--
--   1. THE ORDER BOARD (top centre)  -- a standing statement of what this bay wants. It
--      changes rarely and you should be able to ignore it once you have read it.
--   2. TOASTS (under the board)      -- something JUST happened: a block was refused, a lever
--      threw, a screw was found. Transient, stacked, self-expiring.
--   3. THE STAMP (screen centre)     -- the big one. A bay was cleared, or you died. It
--      interrupts, it animates, and it gets out of the way on its own.
--
-- The old HUD had only layer 1, so a refused block was a line of text that appeared inside a
-- panel you had already stopped reading. Events need to move to be noticed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local Ui = require(ReplicatedStorage:WaitForChild("UiTheme"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Objective = Remotes:WaitForChild("Objective")
local DebugStatus = Remotes:WaitForChild("DebugStatus")
local Toast = Remotes:WaitForChild("Toast")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "ObjectiveHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.Parent = playerGui

local PANEL_W = 500

----------------------------------------------------------------
-- 1. The order board
----------------------------------------------------------------
local board = Ui.panel({
	parent = gui,
	name = "OrderBoard",
	title = "",
	size = UDim2.fromOffset(PANEL_W, 140),
	position = UDim2.new(0.5, 0, 0, 16),
	anchor = Vector2.new(0.5, 0),
	tone = "danger",
	zindex = 2,
})
board.frame.Visible = false

local taskLabel = Ui.text(board.body, {style = "task", text = "", size = UDim2.new(1, 0, 0, 32)})
local hintLabel = Ui.text(board.body, {style = "hint", text = "",
	position = UDim2.fromOffset(0, 34), size = UDim2.new(1, 0, 0, 18), wrap = true})

-- Timer: a brass-framed readout, because a number floating in space reads as debug output.
local timerBox = Instance.new("Frame")
timerBox.Name = "TimerBox"
timerBox.AnchorPoint = Vector2.new(0.5, 0)
timerBox.Position = UDim2.new(0.5, 0, 0, 56)
timerBox.Size = UDim2.fromOffset(150, 40)
timerBox.BackgroundColor3 = Ui.C.ironDark
timerBox.BorderSizePixel = 0
timerBox.ZIndex = board.body.ZIndex + 1
timerBox.Visible = false
timerBox.Parent = board.body
Ui.corner(timerBox, 4)
Ui.stroke(timerBox, Ui.C.brassDim, 1.5)

local timerCaption = Ui.text(timerBox, {style = "caption", text = "", align = Enum.TextXAlignment.Center,
	size = UDim2.new(1, 0, 0, 12), position = UDim2.fromOffset(0, 3)})
local timerValue = Ui.text(timerBox, {style = "number", text = "", textSize = 24,
	size = UDim2.new(1, 0, 0, 24), position = UDim2.fromOffset(0, 14)})

local stepLabels = {}
for i = 1, 5 do
	stepLabels[i] = Ui.text(board.body, {style = "step", text = "",
		position = UDim2.fromOffset(8, 0), size = UDim2.new(1, -16, 0, 17)})
	stepLabels[i].Visible = false
end

local noteLabel = Ui.text(board.body, {style = "note", text = "", wrap = true,
	size = UDim2.new(1, -8, 0, 30)})
noteLabel.Visible = false

----------------------------------------------------------------
-- 2. Toasts
----------------------------------------------------------------
-- A stack under the board. Newest at the top, each one shoving the others down, each one
-- removing itself. Capped, because an obstacle that refuses ten blocks in a row should not
-- own the whole screen.
local TOAST_MAX = 3
local TOAST_LIFE = 4.5   -- long enough to actually read a sentence before it goes
local toasts = {}

local toastHolder = Instance.new("Frame")
toastHolder.Name = "Toasts"
toastHolder.AnchorPoint = Vector2.new(0.5, 0)
toastHolder.Position = UDim2.new(0.5, 0, 0, 170)
toastHolder.Size = UDim2.fromOffset(PANEL_W, 140)
toastHolder.BackgroundTransparency = 1
toastHolder.ZIndex = 4
toastHolder.Parent = gui

local function layoutToasts()
	for i, t in ipairs(toasts) do
		TweenService:Create(t.frame, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
			Position = UDim2.new(0.5, 0, 0, (i - 1) * 38),
		}):Play()
	end
end

local function dismissToast(entry)
	local idx = table.find(toasts, entry)
	if not idx then
		return
	end
	table.remove(toasts, idx)
	local out = TweenService:Create(entry.frame, TweenInfo.new(0.22, Enum.EasingStyle.Quad), {
		BackgroundTransparency = 1,
		Position = entry.frame.Position + UDim2.fromOffset(0, -10),
	})
	for _, d in ipairs(entry.frame:GetDescendants()) do
		if d:IsA("TextLabel") then
			TweenService:Create(d, TweenInfo.new(0.22), {TextTransparency = 1}):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, TweenInfo.new(0.22), {Transparency = 1}):Play()
		end
	end
	out.Completed:Connect(function()
		entry.frame:Destroy()
	end)
	out:Play()
	layoutToasts()
end

local function showToast(text, tone)
	if not text or text == "" then
		return
	end
	-- Normalised to caps. These come from two different server paths -- a guard's rejection
	-- reason ("blades live") and an obstacle's own notice ("BLADES LIVE - CANNOT DROP
	-- THERE") -- and side by side in the same stack the mixed casing read like a bug. The
	-- toast is signage; signage shouts.
	text = text:upper()
	-- Repeat of the message already on top? Refresh it instead of stacking a duplicate --
	-- a guard refusing the same cell twice is one event the player needs to see, not two.
	local top = toasts[1]
	if top and top.text == text then
		top.expires = os.clock() + TOAST_LIFE
		return
	end

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, -10)
	frame.Size = UDim2.fromOffset(PANEL_W - 40, 32)
	frame.BackgroundColor3 = Ui.C.iron
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.ZIndex = 5
	frame.Parent = toastHolder
	Ui.corner(frame, 4)
	Ui.stroke(frame, Ui.tone(tone, Ui.C.brass), 1.5)
	Ui.sheen(frame, 0.25)

	-- a tone-coloured tab on the left edge, so the kind of event reads before the words
	local tab = Instance.new("Frame")
	tab.Size = UDim2.new(0, 4, 1, -10)
	tab.Position = UDim2.fromOffset(5, 5)
	tab.BackgroundColor3 = Ui.tone(tone, Ui.C.brass)
	tab.BorderSizePixel = 0
	tab.ZIndex = 6
	tab.Parent = frame
	Ui.corner(tab, 2)

	Ui.text(frame, {style = "step", text = text, textSize = 14,
		colour = Ui.C.parchment, position = UDim2.fromOffset(18, 0),
		size = UDim2.new(1, -26, 1, 0), zindex = 6})

	local entry = {frame = frame, text = text, expires = os.clock() + TOAST_LIFE}
	table.insert(toasts, 1, entry)
	while #toasts > TOAST_MAX do
		dismissToast(toasts[#toasts])
	end
	layoutToasts()
end

----------------------------------------------------------------
-- 3. The stamp
----------------------------------------------------------------
-- Centre screen, big, brief. Scales down onto the screen like a stamp hitting paper rather
-- than fading in, because the whole point is that you cannot miss it.
local stamp = Ui.panel({
	parent = gui,
	name = "Stamp",
	size = UDim2.fromOffset(440, 96),
	position = UDim2.new(0.5, 0, 0.36, 0),
	anchor = Vector2.new(0.5, 0.5),
	tone = "ok",
	zindex = 8,
})
stamp.frame.Visible = false
stamp.frame.BackgroundTransparency = 0.04

local stampTitle = Ui.text(stamp.body, {style = "big", text = "", size = UDim2.new(1, 0, 0, 40)})
local stampSub = Ui.text(stamp.body, {style = "hint", text = "", textSize = 14,
	position = UDim2.fromOffset(0, 42), size = UDim2.new(1, 0, 0, 18)})

local stampToken = 0
local function showStamp(title, sub, tone)
	stampToken += 1
	local mine = stampToken
	stamp.setTone(tone or "ok")
	stampTitle.Text = title
	stampTitle.TextColor3 = Ui.tone(tone, Ui.C.amber)
	stampSub.Text = sub or ""
	stamp.frame.Visible = true
	stamp.frame.Size = UDim2.fromOffset(560, 122)
	TweenService:Create(stamp.frame, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(440, 96),
	}):Play()

	task.delay(2.4, function()
		if stampToken ~= mine then
			return
		end
		local out = TweenService:Create(stamp.frame, TweenInfo.new(0.3), {BackgroundTransparency = 1})
		TweenService:Create(stampTitle, TweenInfo.new(0.3), {TextTransparency = 1}):Play()
		TweenService:Create(stampSub, TweenInfo.new(0.3), {TextTransparency = 1}):Play()
		out.Completed:Connect(function()
			if stampToken == mine then
				stamp.frame.Visible = false
				stamp.frame.BackgroundTransparency = 0.04
				stampTitle.TextTransparency = 0
				stampSub.TextTransparency = 0
			end
		end)
		out:Play()
	end)
end

----------------------------------------------------------------
-- Wiring
----------------------------------------------------------------
local lastFlash = nil

Objective.OnClientEvent:Connect(function(p)
	if not p then
		board.frame.Visible = false
		lastFlash = nil
		return
	end

	board.frame.Visible = true
	board.setTone(p.tone)
	board.setTitle(p.title or "")
	taskLabel.Text = p.task or ""
	taskLabel.TextColor3 = Ui.tone(p.tone, Ui.C.amber)
	hintLabel.Text = p.hint or ""

	local y = 58
	if p.timer then
		timerCaption.Text = p.timerLabel or ""
		local secs = math.max(0, math.floor(p.timer + 0.5))
		timerValue.Text = string.format("%d:%02d", math.floor(secs / 60), secs % 60)
		timerValue.TextColor3 = (p.timerTone and Ui.tone(p.timerTone))
			or (secs <= 10 and Ui.C.danger)
			or Ui.C.parchment
		timerBox.Position = UDim2.new(0.5, 0, 0, y)
		timerBox.Visible = true
		y += 48
	else
		timerBox.Visible = false
	end

	local used = 0
	for idx, l in ipairs(stepLabels) do
		local text = p.steps and p.steps[idx]
		l.Visible = text ~= nil
		if text then
			used = idx
			l.Text = text
			l.TextColor3 = text:find("%[x%]") and Ui.C.ok
				or text:find("%[%-%]") and Ui.C.ghost
				or Ui.C.parchment
			l.Position = UDim2.fromOffset(8, y + (idx - 1) * 18)
		end
	end
	y += used * 18 + (used > 0 and 4 or 0)

	noteLabel.Visible = p.note ~= nil
	if p.note then
		noteLabel.Text = p.note
		noteLabel.Position = UDim2.fromOffset(4, y)
		y += 32
	end

	board.frame.Size = UDim2.fromOffset(PANEL_W, math.max(120, y + 34))
	toastHolder.Position = UDim2.new(0.5, 0, 0, 16 + board.frame.Size.Y.Offset + 10)

	-- `flash` is the server's refusal channel. It arrives merged into the next objective push
	-- and persists in the payload, so it has to be edge-detected or every subsequent push
	-- re-raises the same toast.
	if p.flash and p.flash ~= lastFlash then
		showToast(p.flash, "warn")
	end
	lastFlash = p.flash
end)

-- Direct event channel: obstacles announce things that are not a change of objective.
Toast.OnClientEvent:Connect(function(text, tone, big)
	if big then
		showStamp(text, nil, tone)
	else
		showToast(text, tone)
	end
end)

-- Bay cleared. Taken from the status feed rather than from the objective payload, because
-- `solved` is the authoritative edge and a bay may clear its objective on the same frame.
local wasSolved = {}
DebugStatus.OnClientEvent:Connect(function(status)
	for i, b in pairs(status.bays or {}) do
		if b.solved and wasSolved[i] == false then
			showStamp("BAY " .. string.format("%02d", i) .. "  CLEARED",
				(b.obstacle or ""):upper(), "ok")
		end
		wasSolved[i] = b.solved or false
	end
end)

-- Death, worth a stamp of its own: the respawn is silent otherwise and in a dark room you
-- genuinely cannot tell you died.
local function watchCharacter(ch)
	local hum = ch:WaitForChild("Humanoid", 5)
	if hum then
		hum.Died:Connect(function()
			showStamp("YOU DIED", "the machine resets", "danger")
		end)
	end
end
player.CharacterAdded:Connect(watchCharacter)
if player.Character then
	watchCharacter(player.Character)
end

-- Toast expiry.
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for i = #toasts, 1, -1 do
		if now >= toasts[i].expires then
			dismissToast(toasts[i])
		end
	end
end)

print("[ObjectiveHud] steampunk HUD online")
