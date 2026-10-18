-- ReplicatedStorage.Obby.Views.Debug.DebugMenu (LocalScript template; Views.PlayerView clones it into
-- PlayerGui for the runner only while ReplicatedStorage.Obby ArcadeDebug == true, so F1 / F2 and the panel
-- do not exist otherwise). Arcade copy of lebot_obby/StarterPlayerScripts/DebugMenu.client.lua: the panel
-- reads Remotes.Status (was DebugStatus) and asks for it with Status:FireServer(); the commands still go
-- through DebugCommand. Its ScreenGui carries ObbyView = true and goes when the copy's Exiting attribute
-- is set.
--
-- DebugMenu (client) -- the scenario picker: jump to any bay, start a clean run on it, and
-- choose whether a second player exists at all.
--
-- Everything shown here is pushed from the server (Status) rather than tracked locally,
-- so the panel cannot drift from what the game actually thinks. F1 hides it for screenshots.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Obby = ReplicatedStorage:WaitForChild("Obby")
local Config = require(Obby:WaitForChild("Config"))

if Obby:GetAttribute("ArcadeDebug") ~= true then
	return
end

local Remotes = Obby:WaitForChild("Remotes")
local DebugCommand = Remotes:WaitForChild("DebugCommand")
local Status = Remotes:WaitForChild("Status")

local connections = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local INK = Color3.fromRGB(232, 236, 244)
local PANEL = Color3.fromRGB(18, 19, 24)
local EDGE = Color3.fromRGB(52, 56, 68)
local LIVE = Color3.fromRGB(90, 230, 130)
local WARM = Color3.fromRGB(255, 180, 90)
local COLD = Color3.fromRGB(110, 170, 255)
local DONE = Color3.fromRGB(120, 240, 140)

local FEED_LABEL = {
	live = "MODE: LIVE ARM",
	solo = "MODE: SOLO",
}
local FEED_HINT = {
	live = "connected to the real SO-101 -- only your hands place a block",
	solo = "you are the operator too: place on the grid below, the arm carries it",
}
local FEED_TINT = {live = LIVE, solo = WARM}

local gui = Instance.new("ScreenGui")
gui.Name = "DebugMenu"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui:SetAttribute("ObbyView", true)
gui.Parent = playerGui

local root = Instance.new("Frame")
root.Size = UDim2.new(0, 300, 0, 400)
root.Position = UDim2.new(0, 16, 0, 16)
root.BackgroundColor3 = PANEL
root.BackgroundTransparency = 0.08
root.BorderSizePixel = 0
root.Parent = gui
Instance.new("UICorner", root).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", root)
stroke.Color = EDGE
stroke.Thickness = 1

local pad = Instance.new("UIPadding", root)
pad.PaddingTop = UDim.new(0, 10)
pad.PaddingBottom = UDim.new(0, 10)
pad.PaddingLeft = UDim.new(0, 10)
pad.PaddingRight = UDim.new(0, 10)

local layout = Instance.new("UIListLayout", root)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function label(text, size, colour, parent)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, size + 6)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextSize = size
	l.TextColor3 = colour or INK
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.LayoutOrder = nextOrder()
	l.Parent = parent or root
	return l
end

local function button(text, parent, tint)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 30)
	b.BackgroundColor3 = tint or Color3.fromRGB(38, 41, 52)
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = INK
	b.Text = text
	b.LayoutOrder = nextOrder()
	b.Parent = parent or root
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

label("DEBUG  -  SCENARIOS", 14)
local hint = label("F1 hides this panel", 11, Color3.fromRGB(140, 146, 160))
hint.Size = UDim2.new(1, 0, 0, 14)

-- Bay grid -------------------------------------------------------------
local grid = Instance.new("Frame")
grid.Size = UDim2.new(1, 0, 0, 96)
grid.BackgroundTransparency = 1
grid.LayoutOrder = nextOrder()
grid.Parent = root

local gl = Instance.new("UIGridLayout", grid)
gl.CellSize = UDim2.new(0, 88, 0, 28)
gl.CellPadding = UDim2.new(0, 6, 0, 6)
gl.SortOrder = Enum.SortOrder.LayoutOrder

local bayButtons = {}
for i = 1, Config.NumBays do
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 88, 0, 28)
	b.BackgroundColor3 = Color3.fromRGB(38, 41, 52)
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.TextColor3 = INK
	b.Text = ("%d"):format(i)
	b.LayoutOrder = i
	b.Parent = grid
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
	local st = Instance.new("UIStroke", b)
	st.Color = EDGE
	st.Thickness = 1
	b.MouseButton1Click:Connect(function()
		DebugCommand:FireServer("teleport", i)
	end)
	bayButtons[i] = {button = b, stroke = st}
end

local current = label("Bay 01  -  Saw", 12, COLD)

local startBtn = button("START RUN HERE  (fresh state)", root, Color3.fromRGB(32, 78, 48))
local resetBtn = button("RESET THIS BAY", root)
local resetAllBtn = button("RESET ALL BAYS", root)
-- Distinct from RESET ALL BAYS, which rebuilds the course and leaves you standing wherever
-- you were -- usually mid-bay, mid-hazard, sometimes dead. This one also puts you back on the
-- spawn with a fresh body, which is the state a demo wants to start from.
local fullResetBtn = button("RESET EVERYTHING  (F2)", root, Color3.fromRGB(86, 34, 40))

-- Player 2 ------------------------------------------------------------
local sep = label("WHO PLACES BLOCKS  (switching resets everything)", 11,
	Color3.fromRGB(140, 146, 160))
sep.Size = UDim2.new(1, 0, 0, 16)

local feedBtn = button("P2: ...", root)
local feedHint = label("", 10, Color3.fromRGB(140, 146, 160))
feedHint.Size = UDim2.new(1, 0, 0, 26)
feedHint.TextWrapped = true
feedHint.Font = Enum.Font.Gotham

local state = {activeBay = 1, feedMode = "solo", bays = {}}

local MODE_CYCLE = {solo = "live", live = "solo"}

startBtn.MouseButton1Click:Connect(function()
	DebugCommand:FireServer("startRun", state.activeBay)
end)
resetBtn.MouseButton1Click:Connect(function()
	DebugCommand:FireServer("resetBay")
end)
resetAllBtn.MouseButton1Click:Connect(function()
	DebugCommand:FireServer("resetAll")
end)
fullResetBtn.MouseButton1Click:Connect(function()
	DebugCommand:FireServer("fullReset")
end)
-- Switching is a hard reset of the whole course, so say so rather than surprising anyone.
feedBtn.MouseButton1Click:Connect(function()
	DebugCommand:FireServer("feedMode", MODE_CYCLE[state.feedMode] or "solo")
end)

local function render()
	for i, entry in ipairs(bayButtons) do
		local info = state.bays[i]
		local isActive = (i == state.activeBay)
		local solved = info and info.solved
		entry.button.Text = info and ("%d  %s"):format(i, info.obstacle) or tostring(i)
		entry.button.BackgroundColor3 = isActive and Color3.fromRGB(28, 54, 86)
			or Color3.fromRGB(38, 41, 52)
		entry.stroke.Color = isActive and COLD or (solved and DONE or EDGE)
		entry.stroke.Thickness = isActive and 2 or 1
		entry.button.TextColor3 = solved and DONE or INK
	end
	local info = state.bays[state.activeBay]
	if info then
		current.Text = ("Bay %02d  -  %s%s"):format(state.activeBay, info.obstacle,
			info.solved and "   [CLEARED]" or "")
		current.TextColor3 = info.solved and DONE or COLD
	end
	feedBtn.Text = FEED_LABEL[state.feedMode] or "P2: ?"
	feedBtn.BackgroundColor3 = Color3.fromRGB(32, 36, 46)
	local tint = FEED_TINT[state.feedMode]
	feedBtn.TextColor3 = tint or INK
	feedHint.Text = FEED_HINT[state.feedMode] or ""
end

table.insert(connections, Status.OnClientEvent:Connect(function(s)
	if type(s) ~= "table" then
		return
	end
	state = s
	render()
end))

table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F1 then
		root.Visible = not root.Visible
	elseif input.KeyCode == Enum.KeyCode.F2 then
		-- Reachable with the panel hidden, which is how you would actually be playing.
		DebugCommand:FireServer("fullReset")
	end
end))

-- Views.PlayerView sets Exiting on this copy before destroying it. (The buttons' connections go
-- with the GUI.)
script:GetAttributeChangedSignal("Exiting"):Connect(function()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	gui:Destroy()
end)

render()
Status:FireServer()
