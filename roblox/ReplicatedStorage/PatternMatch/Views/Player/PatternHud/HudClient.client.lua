-- ReplicatedStorage.PatternMatch.Views.Player.PatternHud.HudClient
-- Pattern Match HUD, driven by the PatternUI remote payload (PatternMatch.Game:payload). A template:
-- Views.PlayerView clones its ScreenGui into PlayerGui for the player role and spectators (never the robot)
-- and destroys it on exit. With the ReadOnly attribute (spectators) it sends nothing: no Q / R, no arrows,
-- and no camera shake (their camera already follows the player's). It asks for the current payload
-- (PatternRefresh) when it starts, and stops the tremor shake when the view exits (Exiting attribute).
--   - Ticket stack (bottom left, small): only the ACTIVE ticket is face up (ticket #, points, mini 4 x 3
--     grid with row A on top and columns 1-4 left to right, like the board seen from the row C side; a
--     stacked cell is split, top color over bottom, with a small "2" badge; age). Waiting tickets peek out
--     behind it as a fanned pile (up to 3 edges) with a "+N waiting" badge. Q / R or the < > arrows cycle
--     the active ticket (TicketCycle remote; PatternMatch.TicketStack has the shared rules), with a quick
--     swap: the old card slides behind the pile, the next slides to the front. A new ticket flies in and
--     tucks onto the back of the pile (badge pulse, "NEW TICKET" chip for 1 s) without changing the active
--     ticket. A completed card gets an "ORDER UP!" stamp and flies up and off (the big ORDER UP text is in
--     3D above the boards). In Hard mode's hidden phase the card's squares go gray, layout kept. About
--     350 x 320 px at 1080p, scaled with the screen height (never below 0.8 of the design size).
--   - Status panel (top right): mode, shift timer (flashes "+3s" on an ORDER UP), score, tickets done,
--     the Hard reveal phase, the event banner and the game message, plus a small robot link badge on the
--     mode line: ROBOT LIVE, MOCK, OFFLINE (matching is frozen) or NO ROBOT (the fake generator).
--   - Results screen at the end of a shift: tickets completed, total points, one line per ticket.
-- While a Tremor is active this client shakes its camera and the boards (PatternMatch.BoardShake,
-- restored exactly afterwards). Everything is hidden while this player is on the mode select screen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch:WaitForChild("Config"))
local BoardShake = require(PatternMatch:WaitForChild("BoardShake"))
local remotes = PatternMatch:WaitForChild("Remotes")
local patternUI = remotes:WaitForChild("PatternUI")
local ticketCycle = remotes:WaitForChild("TicketCycle")
local TicketStack = require(PatternMatch:WaitForChild("TicketStack"))
local cabinet = workspace:WaitForChild("PatternCabinet")
local localPlayer = Players.LocalPlayer

local CAMERA_SHAKE_STUDS = 0.12
local CAMERA_SHAKE_RADIANS = math.rad(0.6)

-- Ticket stack, in design pixels at 1080p (scaled with the screen height).
local STACK_W, STACK_H = 220, 200
local CARD_W, CARD_H = 100, 110    -- the face-up card: a bit over half the old rail card's area (124 x 158)
local ARROW_W = 24
local EDGE_STEP = 5                -- each waiting card peeks out this far up and to the right
local SWAP_REACH = UDim2.fromOffset(48, -14) -- a swapping card slides this far out from behind the pile
local CELL, CELL_GAP = 16, 2
local STACK_BOOST = 1.6           -- the whole stack 1.6x the design size: about 350 x 320 at 1080p
local STACK_MIN_SCALE = 0.8       -- readable floor for small windows
local PAPER = Color3.fromRGB(252, 247, 234)
local PAPER_EDGE = Color3.fromRGB(214, 202, 178)
local INK = Color3.fromRGB(46, 36, 28)
local EMPTY_CELL = Color3.fromRGB(228, 220, 202)
local HIDDEN_CELL = Color3.fromRGB(150, 150, 150)
local ACTIVE_BORDER = Color3.fromRGB(255, 138, 30)
local GOOD = Color3.fromRGB(90, 220, 120)
local SWAP = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TUCK = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FLY = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local screen = script.Parent
local readOnly = screen:GetAttribute("ReadOnly") == true
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

-- Ticket stack ----------------------------------------------------------------------------------------
-- One small stack in the bottom left. Sizes are design pixels at 1080p; a UIScale on the stack follows the
-- screen height times STACK_BOOST, so it is about 350 x 320 at 1080p, and never below STACK_MIN_SCALE so it
-- stays readable in small windows (Studio's viewport).

local stack = Instance.new("Frame")
stack.Name = "Stack"
stack.BackgroundTransparency = 1
stack.AnchorPoint = Vector2.new(0, 1)
stack.Position = UDim2.new(0, 12, 1, -12)
stack.Size = UDim2.fromOffset(STACK_W, STACK_H)
stack.Visible = false
stack.Parent = root
local stackScale = Instance.new("UIScale")
stackScale.Parent = stack
local function fitToScreen()
	local camera = workspace.CurrentCamera
	local height = camera and camera.ViewportSize.Y or 1080
	stackScale.Scale = math.clamp(STACK_BOOST * height / 1080, STACK_MIN_SCALE, 3)
end
fitToScreen()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(fitToScreen)
if workspace.CurrentCamera then
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitToScreen)
end

local FRONT = UDim2.fromOffset(ARROW_W + 6, STACK_H - CARD_H - 2) -- the face-up card's place
local function backPosition(k) -- the k-th waiting card, peeking out up and to the right
	return FRONT + UDim2.fromOffset(k * EDGE_STEP, -k * EDGE_STEP)
end

local edges = {} -- the waiting cards' peeking edges, made once
for k = 1, TicketStack.MAX_EDGES do
	local edge = Instance.new("Frame")
	edge.Name = "Edge" .. k
	edge.BackgroundColor3 = PAPER
	edge.BorderSizePixel = 0
	edge.Position = backPosition(k)
	edge.Size = UDim2.fromOffset(CARD_W, CARD_H)
	edge.ZIndex = 10 - k
	edge.Visible = false
	edge.Parent = stack
	corner(edge, 5)
	local stroke = Instance.new("UIStroke")
	stroke.Color = PAPER_EDGE
	stroke.Thickness = 1.5
	stroke.Parent = edge
	edges[k] = edge
end

local function arrow(name, glyph, key, x)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = glyph
	button.Font = Enum.Font.GothamBlack
	button.TextSize = 22
	button.TextColor3 = INK
	button.AutoButtonColor = true
	button.BackgroundColor3 = PAPER
	button.Position = UDim2.fromOffset(x, FRONT.Y.Offset + CARD_H / 2 - 26)
	button.Size = UDim2.fromOffset(ARROW_W, 38)
	button.ZIndex = 20
	button.Parent = stack
	corner(button, 6)
	text(button, "Key", { Text = key, Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Color3.fromRGB(230, 230, 240),
		Position = UDim2.fromOffset(0, 40), Size = UDim2.fromOffset(ARROW_W, 14), ZIndex = 20 })
	return button
end
local prevButton = arrow("Prev", "<", "Q", 0)
local nextButton = arrow("Next", ">", "R", ARROW_W + 6 + CARD_W + TicketStack.MAX_EDGES * EDGE_STEP + 4)

local badge = text(stack, "Waiting", { Font = Enum.Font.GothamBlack, TextSize = 12, TextColor3 = Color3.new(1, 1, 1),
	BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(214, 98, 24), AnchorPoint = Vector2.new(1, 1),
	Position = backPosition(TicketStack.MAX_EDGES) + UDim2.fromOffset(CARD_W, -3), Size = UDim2.fromOffset(78, 18), Visible = false, ZIndex = 25 })
-- (just above the pile's top edge, so it never covers the face-up card)
corner(badge, 10)
local badgeScale = Instance.new("UIScale")
badgeScale.Parent = badge

local chip = text(stack, "NewTicket", { Text = "NEW TICKET", Font = Enum.Font.GothamBlack, TextSize = 12, TextColor3 = INK,
	BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(255, 214, 60), AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(FRONT.X.Offset + CARD_W / 2, FRONT.Y.Offset - TicketStack.MAX_EDGES * EDGE_STEP - 46),
	Size = UDim2.fromOffset(92, 20), Visible = false, ZIndex = 25 })
corner(chip, 10)

local front = nil       -- { id, card }: the face-up (active) ticket
local known = {}        -- ticket ids seen this shift, to spot arrivals
local lastWaiting = 0
local lastOrderSeq = nil -- seq of the last ORDER UP shown; set from the first payload without animating
local chipToken = 0
local inShiftNow = false

-- The face-up card: ticket number, points, mini 4 x 3 grid, age. Not clickable; cycling is Q / R or < >.
local function newCard(ticket)
	local frame = Instance.new("Frame")
	frame.Name = "Ticket" .. ticket.id
	frame.BackgroundColor3 = PAPER
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromOffset(CARD_W, CARD_H)
	frame.ZIndex = 12
	corner(frame, 6)
	local edge = Instance.new("UIStroke")
	edge.Color = ACTIVE_BORDER
	edge.Thickness = 2.5
	edge.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Parent = frame

	text(frame, "Number", { Text = "#" .. ticket.id, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = INK,
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(6, 4), Size = UDim2.fromOffset(36, 16), ZIndex = 13 })
	local points = text(frame, "Points", { Text = ticket.points .. " pts", Font = Enum.Font.GothamBlack, TextSize = 14,
		TextColor3 = Color3.fromRGB(196, 92, 20), TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -58, 0, 4), Size = UDim2.fromOffset(52, 16), ZIndex = 13 })

	local gridW = Config.gridCols * CELL + (Config.gridCols - 1) * CELL_GAP
	local gridH = Config.gridRows * CELL + (Config.gridRows - 1) * CELL_GAP
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.AnchorPoint = Vector2.new(0.5, 0)
	grid.Position = UDim2.new(0.5, 0, 0, 24)
	grid.Size = UDim2.fromOffset(gridW, gridH)
	grid.ZIndex = 13
	grid.Parent = frame
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
			square.ZIndex = 13
			square.Parent = grid
			corner(square, 3)
			local top = Instance.new("Frame") -- top half: the level 1 block of a stacked cell
			top.Name = "Top"
			top.BorderSizePixel = 0
			top.Size = UDim2.fromScale(1, 0.5)
			top.Visible = false
			top.ZIndex = 14
			top.Parent = square
			local cellBadge = text(square, "Badge", { Text = "2", Font = Enum.Font.GothamBlack, TextSize = 8,
				TextColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, BackgroundColor3 = INK,
				AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(8, 8),
				Visible = false, ZIndex = 15 })
			cellParts[name] = { square = square, top = top, badge = cellBadge }
		end
	end

	local age = text(frame, "Age", { Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = Color3.fromRGB(110, 98, 84),
		TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 7, 1, -17), Size = UDim2.fromOffset(50, 13), ZIndex = 13 })
	frame.Parent = stack
	return { frame = frame, cells = cellParts, points = points, age = age, scale = scale }
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

-- The completed card gets an "ORDER UP! +points" stamp and flies up and off the screen. The big
-- "ORDER UP! +points" itself pops in above the boards in 3D (PatternMatch.Celebrate on the server, the same
-- moment as the attract demo's COMPLETE!), so the HUD doesn't repeat it.
local function orderUp(info, card)
	card.frame.ZIndex = 30
	local stamp = text(card.frame, "Stamp", { Text = "ORDER UP!\n+" .. info.points, Font = Enum.Font.GothamBlack, TextSize = 16,
		TextColor3 = Color3.fromRGB(30, 150, 60), Rotation = -12, BackgroundTransparency = 0.15, BackgroundColor3 = PAPER,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(CARD_W - 10, 46), ZIndex = 31 })
	corner(stamp, 6)
	task.delay(0.35, function()
		local p = card.frame.Position
		TweenService:Create(card.frame, FLY, { Position = p + UDim2.fromOffset(40, -1400), Rotation = 18 }):Play() -- up and out
		task.delay(0.95, function() card.frame:Destroy() end)
	end)
end

-- A new ticket: a small card flies in and tucks onto the back of the pile; the badge pulses and the
-- "NEW TICKET" chip flashes for 1 s. The active (face-up) ticket doesn't change.
local function arrive(waiting)
	local mini = Instance.new("Frame")
	mini.Name = "Arriving"
	mini.BackgroundColor3 = PAPER
	mini.BorderSizePixel = 0
	mini.Size = UDim2.fromOffset(CARD_W * 0.5, CARD_H * 0.5)
	mini.Position = UDim2.fromOffset(STACK_W + 260, -120)
	mini.Rotation = 20
	mini.ZIndex = 5
	mini.Parent = stack
	corner(mini, 4)
	local stroke = Instance.new("UIStroke")
	stroke.Color = PAPER_EDGE
	stroke.Thickness = 1.5
	stroke.Parent = mini
	local dest = backPosition(math.max(1, TicketStack.pileEdges(waiting)))
	TweenService:Create(mini, TUCK, { Position = dest, Size = UDim2.fromOffset(CARD_W, CARD_H), Rotation = 0 }):Play()
	task.delay(TUCK.Time + 0.02, function() mini:Destroy() end)

	badgeScale.Scale = 1.4
	TweenService:Create(badgeScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	chipToken += 1
	local mine = chipToken
	chip.Visible = true
	chip.BackgroundTransparency, chip.TextTransparency = 0, 0
	task.delay(1, function()
		if chipToken == mine then
			chip.Visible = false
		end
	end)
end

-- The active ticket changed: the old face-up card slides behind the pile (or flies off on an ORDER UP)
-- and the new one slides to the front, about 0.2 s.
local function swapFront(ticket, flyInfo)
	local previous = front
	local card = newCard(ticket)
	card.frame.Position = FRONT + SWAP_REACH
	card.scale.Scale = 0.94
	TweenService:Create(card.frame, SWAP, { Position = FRONT }):Play()
	TweenService:Create(card.scale, SWAP, { Scale = 1 }):Play()
	front = { id = ticket.id, card = card }
	if previous then
		if flyInfo then
			orderUp(flyInfo, previous.card)
		else
			local old = previous.card
			old.frame.ZIndex = 8 -- under the incoming card and the pile's edges
			TweenService:Create(old.frame, SWAP, { Position = FRONT + SWAP_REACH }):Play()
			TweenService:Create(old.scale, SWAP, { Scale = 0.94 }):Play()
			task.delay(SWAP.Time + 0.02, function() old.frame:Destroy() end)
		end
	end
end

local function clearStack()
	if front then
		front.card.frame:Destroy()
		front = nil
	end
	table.clear(known)
	lastWaiting = 0
	for _, edge in ipairs(edges) do
		edge.Visible = false
	end
	badge.Visible = false
	chip.Visible = false
end

local function cycle(dir)
	if not readOnly and inShiftNow and lastWaiting > 0 then
		ticketCycle:FireServer(dir)
	end
end
prevButton.Visible, nextButton.Visible = not readOnly, not readOnly
prevButton.Activated:Connect(function() cycle(TicketStack.ARROWS.Prev) end)
nextButton.Activated:Connect(function() cycle(TicketStack.ARROWS.Next) end)
UserInputService.InputBegan:Connect(function(input)
	if UserInputService:GetFocusedTextBox() then
		return -- typing in chat
	end
	local dir = TicketStack.KEYS[input.KeyCode]
	if dir then
		cycle(dir)
	end
end)

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
-- Robot link badge, right end of the mode line (payload.robot).
local ROBOT_BADGES = {
	live = { "ROBOT LIVE", Color3.fromRGB(46, 160, 82) },
	mock = { "MOCK", Color3.fromRGB(70, 110, 200) },
	offline = { "OFFLINE", Color3.fromRGB(200, 60, 50) },
	fake = { "NO ROBOT", Color3.fromRGB(96, 96, 108) },
}
local robotBadge = text(modeLabel, "RobotBadge", { Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Color3.new(1, 1, 1),
	AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.fromOffset(0, 16),
	AutomaticSize = Enum.AutomaticSize.X, TextWrapped = false, BackgroundTransparency = 0, Visible = false })
corner(robotBadge, 8)
local badgePad = Instance.new("UIPadding")
badgePad.PaddingLeft, badgePad.PaddingRight = UDim.new(0, 7), UDim.new(0, 7)
badgePad.Parent = robotBadge
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
	if on and not readOnly then
		local rng = Random.new()
		RunService:BindToRenderStep("PatternTremor", Enum.RenderPriority.Camera.Value + 1, function()
			local camera = workspace.CurrentCamera
			camera.CFrame *= CFrame.new(rng:NextNumber(-CAMERA_SHAKE_STUDS, CAMERA_SHAKE_STUDS),
				rng:NextNumber(-CAMERA_SHAKE_STUDS, CAMERA_SHAKE_STUDS), 0)
				* CFrame.Angles(0, 0, rng:NextNumber(-CAMERA_SHAKE_RADIANS, CAMERA_SHAKE_RADIANS))
		end)
	end
	if on then
		boardShake = BoardShake.start({ cabinet:WaitForChild("TargetBoard"), cabinet:WaitForChild("LiveBoard") })
	else
		pcall(RunService.UnbindFromRenderStep, RunService, "PatternTremor") -- not bound on a read-only copy
		if boardShake then
			boardShake:stop()
			boardShake = nil
		end
	end
end

-- The view is leaving (role or game change): put the camera and the boards back.
screen:GetAttributeChangedSignal("Exiting"):Connect(function()
	setTremor(false)
end)

-- Payload ---------------------------------------------------------------------------------------------

local function updateStack(p)
	local tickets = p.tickets or {}
	local hidden = p.revealPhase == "hide"
	local waiting = TicketStack.waitingCount(#tickets)
	local present, active = {}, nil
	for _, ticket in ipairs(tickets) do
		present[ticket.id] = true
		if ticket.id == p.activeId then
			active = ticket
		end
	end
	active = active or tickets[1]

	local info = p.orderUp
	local newOrder = info ~= nil and info.seq ~= lastOrderSeq

	-- Arrivals: tickets not seen before that aren't the face-up one (the first ticket of a shift, or the
	-- one an empty rail gets right after an ORDER UP, goes straight to the front instead).
	local firstLook = next(known) == nil
	for _, ticket in ipairs(tickets) do
		if not known[ticket.id] then
			known[ticket.id] = true
			if not firstLook and (active == nil or ticket.id ~= active.id) then
				arrive(waiting)
			end
		end
	end

	if active and (front == nil or front.id ~= active.id) then
		local flown = newOrder and front ~= nil and info.id == front.id and not present[front.id]
		swapFront(active, flown and info or nil)
	elseif active == nil and front ~= nil then
		front.card.frame:Destroy()
		front = nil
	end
	if front and active then
		paintCard(front.card, active, hidden)
	end

	local edgeCount = TicketStack.pileEdges(waiting)
	for k, edge in ipairs(edges) do
		edge.Visible = k <= edgeCount
	end
	local badgeText = TicketStack.badgeText(waiting)
	badge.Visible = badgeText ~= nil
	badge.Text = badgeText or ""
	prevButton.TextTransparency = waiting > 0 and 0 or 0.7
	nextButton.TextTransparency = waiting > 0 and 0 or 0.7
	lastWaiting = waiting

	if newOrder then
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
	inShiftNow = inShift
	stack.Visible = inShift
	if inShift then
		updateStack(p)
	else
		clearStack()
	end

	modeLabel.Text = (p.mode and (string.upper(p.mode) .. " MODE   ") or "") .. (inShift and "SHIFT" or string.upper(p.state))
	timerRow.Visible = (p.timeLeft or 0) > 0 and (inShift or p.state == "ModeSelect")
	timerLabel.Text = formatTime(p.timeLeft)
	timerLabel.TextColor3 = inShift and (p.timeLeft or 0) <= 15 and Color3.fromRGB(255, 90, 70) or Color3.new(1, 1, 1)
	scoreLabel.Text = string.format("Score %d   Tickets %d", p.score or 0, p.completedCount or 0)
	local badge = ROBOT_BADGES[p.robot]
	robotBadge.Visible = badge ~= nil
	if badge then
		robotBadge.Text, robotBadge.BackgroundColor3 = badge[1], badge[2]
	end

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

remotes:WaitForChild("PatternRefresh"):FireServer() -- the current state, right away
