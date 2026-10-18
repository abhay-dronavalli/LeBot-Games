-- StarterGui.PatternHud.HudClient
-- Pattern Match HUD, driven by the PatternUI remote payload (PatternMatch.Game:payload):
--   - Ticket rail (bottom left, Papa's-style): paper ticket cards standing on a rail along the bottom edge,
--     oldest on the left, clear of the top-left chat and Roblox buttons and the top-right status panel.
--     Each card shows a mini 4 x 3 grid of the pattern (row A on top, columns 1-4 left to right, like
--     the board seen from the row C side; a stacked cell is split, top color over bottom color, with a
--     small "2" badge), its point value and its age. The active ticket is raised with a colored border.
--     Clicking a card makes it active (TicketPick remote). New cards slide in; a completed card flies off
--     with an "ORDER UP!" stamp and its points (the big ORDER UP text is in 3D above the boards). In Hard
--     mode's hidden phase the squares go gray, layout kept.
--   - Status panel (top right): mode, shift timer (flashes "+3s" on an ORDER UP), score, tickets done,
--     the Hard reveal phase, the event banner and the game message.
--   - Results screen at the end of a shift: tickets completed, total points, one line per ticket.
-- While a Tremor is active this client shakes its camera and the boards (PatternMatch.BoardShake,
-- restored exactly afterwards). Everything is hidden while this player is on the mode select screen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch:WaitForChild("Config"))
local BoardShake = require(PatternMatch:WaitForChild("BoardShake"))
local remotes = PatternMatch:WaitForChild("Remotes")
local patternUI = remotes:WaitForChild("PatternUI")
local ticketPick = remotes:WaitForChild("TicketPick")
local cabinet = workspace:WaitForChild("PatternCabinet")
local localPlayer = Players.LocalPlayer

local CAMERA_SHAKE_STUDS = 0.12
local CAMERA_SHAKE_RADIANS = math.rad(0.6)

local CARD_W, CARD_H = 124, 158
local CARD_GAP = 14
local RAIL_X, RAIL_BOTTOM = 16, 12 -- rail offset from the screen's left and bottom edges
local RAIL_H = CARD_H + 30
local CELL, CELL_GAP = 22, 3
local PAPER = Color3.fromRGB(252, 247, 234)
local PAPER_EDGE = Color3.fromRGB(214, 202, 178)
local INK = Color3.fromRGB(46, 36, 28)
local EMPTY_CELL = Color3.fromRGB(228, 220, 202)
local HIDDEN_CELL = Color3.fromRGB(150, 150, 150)
local ACTIVE_BORDER = Color3.fromRGB(255, 138, 30)
local GOOD = Color3.fromRGB(90, 220, 120)
local SLIDE = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHIFT = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLY = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local screen = script.Parent
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling -- a card's contents always draw over the card itself

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundTransparency = 1
root.Parent = screen

local function text(parent, name, props)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 18
	label.TextWrapped = true
	label.Text = ""
	for k, v in pairs(props or {}) do
		label[k] = v
	end
	label.Parent = parent
	return label
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

-- Ticket rail -----------------------------------------------------------------------------------------

local rail = Instance.new("Frame")
rail.Name = "Rail"
rail.BackgroundTransparency = 1
rail.AnchorPoint = Vector2.new(0, 1)
rail.Position = UDim2.new(0, RAIL_X, 1, -RAIL_BOTTOM)
rail.Size = UDim2.fromOffset(Config.ticketRailMax * (CARD_W + CARD_GAP) + CARD_GAP, RAIL_H)
rail.Parent = root

local bar = Instance.new("Frame") -- the metal rail the tickets hang from
bar.Name = "Bar"
bar.BorderSizePixel = 0
bar.BackgroundColor3 = Color3.fromRGB(70, 74, 82)
bar.Position = UDim2.new(0, 0, 1, -8) -- along the bottom; the cards stand on it
bar.Size = UDim2.new(1, 0, 0, 8)
bar.ZIndex = 5
bar.Parent = rail
corner(bar, 4)
local barShine = Instance.new("UIGradient")
barShine.Color = ColorSequence.new(Color3.fromRGB(200, 205, 214), Color3.fromRGB(70, 74, 82))
barShine.Rotation = 90
barShine.Parent = bar

local cards = {}      -- ticket id -> { button, cells = { cell -> { bottom, top, badge } }, points, age, stroke, scale }
local lastOrderSeq = nil -- seq of the last ORDER UP shown; set from the first payload without animating

local function slotPosition(index, active)
	return UDim2.fromOffset(CARD_GAP + (index - 1) * (CARD_W + CARD_GAP), RAIL_H - 8 - CARD_H - (active and 10 or 2))
end

local function newCard(ticket)
	local button = Instance.new("TextButton")
	button.Name = "Ticket" .. ticket.id
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundColor3 = PAPER
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(CARD_W, CARD_H)
	button.ZIndex = 2
	corner(button, 6)
	local edge = Instance.new("UIStroke")
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Color = PAPER_EDGE
	edge.Thickness = 2
	edge.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button

	local clip = Instance.new("Frame") -- the clip holding the ticket on the rail
	clip.Name = "Clip"
	clip.BorderSizePixel = 0
	clip.BackgroundColor3 = Color3.fromRGB(150, 155, 165)
	clip.AnchorPoint = Vector2.new(0.5, 1)
	clip.Position = UDim2.new(0.5, 0, 1, 8) -- holds the card's foot on the rail
	clip.Size = UDim2.fromOffset(26, 14)
	clip.ZIndex = 6
	clip.Parent = button
	corner(clip, 3)

	text(button, "Number", { Text = "#" .. ticket.id, Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(9, 9), Size = UDim2.fromOffset(50, 18), ZIndex = 3 })
	local points = text(button, "Points", { Text = ticket.points .. " pts", Font = Enum.Font.GothamBlack, TextSize = 15,
		TextColor3 = Color3.fromRGB(196, 92, 20), TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -64, 0, 9), Size = UDim2.fromOffset(55, 18), ZIndex = 3 })

	local gridW = Config.gridCols * CELL + (Config.gridCols - 1) * CELL_GAP
	local gridH = Config.gridRows * CELL + (Config.gridRows - 1) * CELL_GAP
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.AnchorPoint = Vector2.new(0.5, 0)
	grid.Position = UDim2.new(0.5, 0, 0, 34)
	grid.Size = UDim2.fromOffset(gridW, gridH)
	grid.ZIndex = 3
	grid.Parent = button
	local cellParts = {}
	for row = 1, Config.gridRows do
		for col = 1, Config.gridCols do
			local name = string.sub("ABCDEFGHIJ", row, row) .. col
			local square = Instance.new("Frame")
			square.Name = name
			square.BorderSizePixel = 0
			square.BackgroundColor3 = EMPTY_CELL
			square.Position = UDim2.fromOffset((col - 1) * (CELL + CELL_GAP), (row - 1) * (CELL + CELL_GAP))
			square.Size = UDim2.fromOffset(CELL, CELL)
			square.ClipsDescendants = true
			square.ZIndex = 3
			square.Parent = grid
			corner(square, 3)
			local top = Instance.new("Frame") -- top half: the level 1 block of a stacked cell
			top.Name = "Top"
			top.BorderSizePixel = 0
			top.Size = UDim2.fromScale(1, 0.5)
			top.Visible = false
			top.ZIndex = 4
			top.Parent = square
			local badge = text(square, "Badge", { Text = "2", Font = Enum.Font.GothamBlack, TextSize = 10,
				TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, BackgroundColor3 = INK,
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(10, 10),
				Visible = false, ZIndex = 5 })
			cellParts[name] = { square = square, top = top, badge = badge }
		end
	end

	local age = text(button, "Age", { Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = Color3.fromRGB(110, 98, 84),
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 9, 1, -24), Size = UDim2.fromOffset(70, 16), ZIndex = 3 })
	local activeTag = text(button, "Active", { Text = "ACTIVE", Font = Enum.Font.GothamBlack, TextSize = 12,
		TextColor3 = ACTIVE_BORDER, TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -64, 1, -24), Size = UDim2.fromOffset(55, 16), Visible = false, ZIndex = 3 })

	button.Activated:Connect(function()
		ticketPick:FireServer(ticket.id)
	end)
	button.MouseEnter:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.1), { Scale = scale:GetAttribute("Base") and scale:GetAttribute("Base") + 0.03 or 1.03 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.1), { Scale = scale:GetAttribute("Base") or 1 }):Play()
	end)

	button.Parent = rail
	return { button = button, cells = cellParts, points = points, age = age, edge = edge, scale = scale, activeTag = activeTag, ticket = ticket }
end

local function paintCard(card, ticket, hidden)
	for name, parts in pairs(card.cells) do
		local tower = ticket.cells[name]
		local bottom = tower and tower[1]
		local top = tower and tower[2]
		local function colorOf(colorName)
			if hidden then return HIDDEN_CELL end
			return Config.colors[colorName] or HIDDEN_CELL
		end
		parts.square.BackgroundColor3 = bottom and colorOf(bottom) or EMPTY_CELL
		parts.top.Visible = top ~= nil
		parts.badge.Visible = top ~= nil
		if top then
			parts.top.BackgroundColor3 = colorOf(top)
		end
	end
	local age = ticket.age or 0
	card.age.Text = string.format("%d:%02d", age // 60, age % 60)
	card.age.TextColor3 = age >= 40 and Color3.fromRGB(200, 60, 40) or Color3.fromRGB(110, 98, 84)
end

local function setActiveLook(card, active)
	card.edge.Color = active and ACTIVE_BORDER or PAPER_EDGE
	card.edge.Thickness = active and 4 or 2
	card.activeTag.Visible = active
	card.button.ZIndex = active and 4 or 2
	card.scale:SetAttribute("Base", active and 1.06 or 1)
	TweenService:Create(card.scale, SHIFT, { Scale = active and 1.06 or 1 }):Play()
end

-- The completed card gets an "ORDER UP! +points" stamp and flies up and off the screen. The big
-- "ORDER UP! +points" itself pops in above the boards in 3D (PatternMatch.Celebrate on the server, the same
-- moment as the attract demo's COMPLETE!), so the HUD doesn't repeat it.
local function orderUp(info, card)
	if card then
		local stamp = text(card.button, "Stamp", { Text = "ORDER UP!\n+" .. info.points, Font = Enum.Font.GothamBlack, TextSize = 20,
			TextColor3 = Color3.fromRGB(30, 150, 60), Rotation = -12, BackgroundTransparency = 0.15, BackgroundColor3 = PAPER,
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(CARD_W - 10, 60), ZIndex = 8 })
		corner(stamp, 6)
		task.delay(0.35, function()
			local p = card.button.Position
			TweenService:Create(card.button, FLY, { Position = p + UDim2.fromOffset(60, -1400), Rotation = 18 }):Play() -- up and out
			task.delay(0.95, function() card.button:Destroy() end)
		end)
	end
end

-- Status panel ----------------------------------------------------------------------------------------

local panel = Instance.new("Frame")
panel.Name = "Status"
panel.AnchorPoint = Vector2.new(1, 0)
panel.Position = UDim2.new(1, -16, 0, 10)
panel.Size = UDim2.fromOffset(270, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = Color3.fromRGB(20, 18, 28)
panel.BackgroundTransparency = 0.25
panel.Parent = root
corner(panel, 10)
local pad = Instance.new("UIPadding")
pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 10)
pad.Parent = panel
local list = Instance.new("UIListLayout")
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Padding = UDim.new(0, 2)
list.Parent = panel

local function line(name, order, height, size, props)
	local label = text(panel, name, props)
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, height)
	label.TextSize = size
	label.TextXAlignment = Enum.TextXAlignment.Left
	return label
end

local modeLabel = line("Mode", 1, 20, 15, { Font = Enum.Font.GothamBold, TextColor3 = Color3.fromRGB(190, 180, 255) })
local timerRow = Instance.new("Frame")
timerRow.Name = "TimerRow"
timerRow.LayoutOrder = 2
timerRow.BackgroundTransparency = 1
timerRow.Size = UDim2.new(1, 0, 0, 44)
timerRow.Parent = panel
local timerLabel = text(timerRow, "Timer", { Font = Enum.Font.GothamBlack, TextSize = 40, TextXAlignment = Enum.TextXAlignment.Left,
	Size = UDim2.new(0.6, 0, 1, 0) })
local bonusLabel = text(timerRow, "Bonus", { Font = Enum.Font.GothamBlack, TextSize = 26, TextColor3 = GOOD, TextTransparency = 1,
	TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromScale(0.6, 0), Size = UDim2.new(0.4, 0, 1, 0) })
local scoreLabel = line("Score", 3, 22, 18, { Font = Enum.Font.GothamBold })
local revealLabel = line("Reveal", 4, 22, 16, { Font = Enum.Font.GothamBold, Visible = false })
local eventLabel = line("Event", 5, 26, 18, { Font = Enum.Font.GothamBold, TextColor3 = Color3.fromRGB(255, 210, 60), Visible = false })
local messageLabel = line("Message", 6, 40, 15, { TextColor3 = Color3.fromRGB(220, 220, 230) })

-- Results screen --------------------------------------------------------------------------------------

local results = Instance.new("Frame")
results.Name = "Results"
results.AnchorPoint = Vector2.new(0.5, 0.5)
results.Position = UDim2.fromScale(0.5, 0.52)
results.Size = UDim2.fromOffset(460, 360)
results.BackgroundColor3 = PAPER
results.Visible = false
results.Parent = root
corner(results, 12)
local resultsEdge = Instance.new("UIStroke")
resultsEdge.Thickness = 3
resultsEdge.Color = PAPER_EDGE
resultsEdge.Parent = results
text(results, "Title", { Text = "SHIFT OVER", Font = Enum.Font.GothamBlack, TextSize = 40, TextColor3 = INK,
	Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 46) })
local resultsSummary = text(results, "Summary", { Font = Enum.Font.GothamBold, TextSize = 22, TextColor3 = Color3.fromRGB(196, 92, 20),
	Position = UDim2.fromOffset(0, 66), Size = UDim2.new(1, 0, 0, 56) })
local resultsList = text(results, "List", { Font = Enum.Font.Code, TextSize = 16, TextColor3 = INK, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(30, 132), Size = UDim2.new(1, -60, 1, -150) })

-- Tremor ----------------------------------------------------------------------------------------------

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

-- Payload ---------------------------------------------------------------------------------------------

local function updateRail(p)
	local hidden = p.revealPhase == "hide"
	local present = {}
	for index, ticket in ipairs(p.tickets or {}) do
		present[ticket.id] = true
		local card = cards[ticket.id]
		local active = ticket.id == p.activeId
		if not card then
			card = newCard(ticket)
			cards[ticket.id] = card
			-- slide in from the right end of the rail
			card.button.Position = slotPosition(index, active) + UDim2.fromOffset(CARD_W * 2, 40)
			card.button.Rotation = 8
			TweenService:Create(card.button, SLIDE, { Position = slotPosition(index, active), Rotation = 0 }):Play()
		else
			TweenService:Create(card.button, SHIFT, { Position = slotPosition(index, active) }):Play()
		end
		paintCard(card, ticket, hidden)
		if card.isActive ~= active then
			card.isActive = active
			setActiveLook(card, active)
		end
	end
	-- Cards that left the rail: the ORDER UP one flies off with its stamp, any other just goes.
	local info = p.orderUp
	local newOrder = info ~= nil and info.seq ~= lastOrderSeq
	local flown = false
	for id, card in pairs(cards) do
		if not present[id] then
			cards[id] = nil
			if newOrder and info.id == id then
				orderUp(info, card)
				flown = true
			else
				card.button:Destroy()
			end
		end
	end
	if newOrder then
		if not flown then
			orderUp(info, nil)
		end
		bonusLabel.Text = "+" .. (info.bonus or Config.ticketTimeBonus) .. "s"
		bonusLabel.TextTransparency = 0
		TweenService:Create(bonusLabel, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1 }):Play()
		lastOrderSeq = info.seq
	end
end

local function formatTime(s)
	s = math.max(0, s or 0)
	return string.format("%d:%02d", s // 60, s % 60)
end

patternUI.OnClientEvent:Connect(function(p)
	if lastOrderSeq == nil then
		lastOrderSeq = p.orderUp and p.orderUp.seq or 0 -- don't replay an ORDER UP from before this player joined
	end
	-- The mode select screen replaces the HUD for the player who is choosing.
	root.Visible = not (p.state == "ModeSelect" and p.chooserUserId == localPlayer.UserId)

	local inShift = p.state == "Shift"
	rail.Visible = inShift
	if inShift then
		updateRail(p)
	else
		for id, card in pairs(cards) do
			card.button:Destroy()
			cards[id] = nil
		end
	end

	modeLabel.Text = (p.mode and (string.upper(p.mode) .. " MODE   ") or "") .. (inShift and "SHIFT" or string.upper(p.state))
	timerRow.Visible = (p.timeLeft or 0) > 0 and (inShift or p.state == "ModeSelect")
	timerLabel.Text = formatTime(p.timeLeft)
	timerLabel.TextColor3 = inShift and (p.timeLeft or 0) <= 15 and Color3.fromRGB(255, 90, 70) or Color3.new(1, 1, 1)
	scoreLabel.Text = string.format("Score %d   Tickets %d", p.score or 0, p.completedCount or 0)

	revealLabel.Visible = p.revealPhase ~= nil
	if p.revealPhase then
		revealLabel.Text = string.format("COLORS %s %ds", p.revealPhase == "show" and "VISIBLE" or "HIDDEN", p.revealTimeLeft or 0)
		revealLabel.TextColor3 = p.revealPhase == "show" and GOOD or Color3.fromRGB(180, 180, 190)
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

	messageLabel.Text = p.message or ""

	results.Visible = p.state == "Results"
	if p.state == "Results" then
		local done = p.completed or {}
		resultsSummary.Text = string.format("%d ticket%s completed\n%d points", #done, #done == 1 and "" or "s", p.score or 0)
		local rows = {}
		for _, t in ipairs(done) do
			local what = string.format("%d block%s%s", t.blocks, t.blocks == 1 and "" or "s", t.stacked and ", stacked" or "")
			table.insert(rows, string.format("#%-3d %-18s %3d pts %4ds", t.id, what, t.points, t.seconds or 0))
		end
		if #rows == 0 then
			rows = { "No tickets this shift." }
		end
		if #rows > 10 then
			local more = #rows - 9
			rows = { table.unpack(rows, 1, 9) }
			table.insert(rows, string.format("... and %d more", more))
		end
		resultsList.Text = table.concat(rows, "\n")
	end
end)

