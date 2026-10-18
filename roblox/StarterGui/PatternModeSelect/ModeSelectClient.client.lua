-- StarterGui.PatternModeSelect.ModeSelectClient
-- Mode select screen for the player who pressed "Play Pattern Match" (the PatternUI payload's chooser).
-- The camera flies to a fixed shot of the cabinet on its floating island, two tiles (EASY / HARD) send
-- the pick through the PatternPick remote, and a countdown shows the auto-pick. Everyone else keeps
-- the HUD, which says who is choosing.
-- The shot hides the Baseplate and SpawnLocation on this client only (LocalTransparencyModifier), so
-- the island under the cabinet floats in open sky. They come back when the camera returns.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch:WaitForChild("Config"))
local remotes = PatternMatch:WaitForChild("Remotes")
local patternUI = remotes:WaitForChild("PatternUI")
local patternPick = remotes:WaitForChild("PatternPick")
local cabinet = workspace:WaitForChild("PatternCabinet")
local localPlayer = Players.LocalPlayer

local VISTA_HIDE = { "Baseplate", "SpawnLocation" } -- hidden on this client during the shot
local SHOT_FROM = Vector3.new(-30, 17, 28)            -- camera, relative to the cabinet floor's center
local SHOT_AT = Vector3.new(2, -4, 0)                 -- look-at point, same frame
local FLY = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RETURN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local HOVER = TweenInfo.new(0.12)

local NEUTRAL = Color3.fromRGB(200, 200, 200)
local GRAYED = Color3.fromRGB(110, 110, 110)
-- Picture art on a 3 x 4 grid (row by row, A1..C4). Easy: four colored targets. Hard: the same targets
-- grayed out except one.
local EASY_ART = { [1] = Config.colors.red, [6] = Config.colors.teal, [8] = Config.colors.purple, [11] = Config.colors.yellow }
local HARD_ART = { [1] = GRAYED, [6] = Config.colors.teal, [8] = GRAYED, [11] = GRAYED }

local TILES = {
	{ key = "easy", title = "EASY", line = "Colors always visible", art = EASY_ART },
	{ key = "hard", title = "HARD", line = "Colors flash on and off. Events every " .. Config.hard.eventEvery .. "s", art = HARD_ART },
}

local screen = script.Parent

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromScale(1, 1)
root.BackgroundTransparency = 1
root.Visible = false
root.Parent = screen

local function label(name, parent, text, textSize, props)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextColor3 = Color3.new(1, 1, 1)
	l.Font = Enum.Font.GothamBold
	l.TextSize = textSize
	l.TextWrapped = true
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

-- Dark edge on text drawn straight over the 3D shot, so it reads against sky and grass alike.
local function outline(textLabel)
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(0, 0, 0)
	s.Thickness = 2
	s.Parent = textLabel
end

local heading = label("Heading", root, "Choose a mode", 34,
	{ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.08, 0), Size = UDim2.new(1, -32, 0, 44) })
outline(heading)
local countdown = label("Countdown", root, "", 24,
	{ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.94, 0), Size = UDim2.new(1, -32, 0, 32) })
outline(countdown)
local confirm = label("Confirm", root, "", 64,
	{ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -32, 0, 90), Visible = false })
outline(confirm)

local row = Instance.new("Frame")
row.Name = "Tiles"
row.AnchorPoint = Vector2.new(0.5, 0.5)
row.Position = UDim2.fromScale(0.5, 0.52)
row.Size = UDim2.new(1, -32, 0.6, 0)
row.BackgroundTransparency = 1
row.Parent = root
local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Horizontal
rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
rowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
rowLayout.Padding = UDim.new(0.04, 0)
rowLayout.Parent = row

local sent = false

-- Picture slot: an ImageLabel (Image empty for now) holding UI-frame art. To use a real image later,
-- set Picture.Image and delete Picture.Art.
local function picture(parent, art)
	local slot = Instance.new("ImageLabel")
	slot.Name = "Picture"
	slot.AnchorPoint = Vector2.new(0.5, 0)
	slot.Position = UDim2.fromScale(0.5, 0.06)
	slot.Size = UDim2.fromScale(0.86, 0.5)
	slot.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	slot.Image = ""
	slot.ScaleType = Enum.ScaleType.Fit
	slot.Parent = parent

	local grid = Instance.new("Frame")
	grid.Name = "Art"
	grid.AnchorPoint = Vector2.new(0.5, 0.5)
	grid.Position = UDim2.fromScale(0.5, 0.5)
	grid.Size = UDim2.fromScale(0.85, 0.85)
	grid.BackgroundTransparency = 1
	grid.Parent = slot
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = Config.gridCols / Config.gridRows
	ratio.Parent = grid
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(1 / Config.gridCols, -6, 1 / Config.gridRows, -6)
	layout.CellPadding = UDim2.fromOffset(6, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for i = 1, Config.gridCols * Config.gridRows do
		local square = Instance.new("Frame")
		square.LayoutOrder = i
		square.BorderSizePixel = 0
		square.BackgroundColor3 = art[i] or NEUTRAL
		square.Parent = grid
	end
end

for i, spec in ipairs(TILES) do
	local tile = Instance.new("TextButton")
	tile.Name = spec.title
	tile.LayoutOrder = i
	tile.Text = ""
	tile.AutoButtonColor = false
	tile.BackgroundColor3 = Color3.new(0, 0, 0)
	tile.Size = UDim2.fromScale(0.42, 1)
	tile.Parent = row
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 0.8
	ratio.Parent = tile
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = tile
	local hoverOutline = Instance.new("UIStroke")
	hoverOutline.Color = Color3.new(1, 1, 1)
	hoverOutline.Thickness = 4
	hoverOutline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	hoverOutline.Enabled = false
	hoverOutline.Parent = tile
	local scale = Instance.new("UIScale")
	scale.Parent = tile

	picture(tile, spec.art)
	label("Title", tile, spec.title, 40, { Position = UDim2.fromScale(0, 0.6), Size = UDim2.fromScale(1, 0.16), TextScaled = true })
	label("Line", tile, spec.line, 18, {
		Position = UDim2.fromScale(0.06, 0.78), Size = UDim2.fromScale(0.88, 0.18),
		Font = Enum.Font.GothamMedium, TextScaled = true, TextColor3 = Color3.fromRGB(220, 220, 220),
	})

	tile.MouseEnter:Connect(function()
		hoverOutline.Enabled = true
		TweenService:Create(scale, HOVER, { Scale = 1.06 }):Play()
	end)
	tile.MouseLeave:Connect(function()
		hoverOutline.Enabled = false
		TweenService:Create(scale, HOVER, { Scale = 1 }):Play()
	end)
	tile.Activated:Connect(function()
		if not sent then
			sent = true
			patternPick:FireServer(spec.key)
		end
	end)
end

local function setVistaHidden(hidden)
	local modifier = hidden and 1 or 0
	for _, name in ipairs(VISTA_HIDE) do
		local thing = workspace:FindFirstChild(name)
		if thing then
			local all = thing:GetDescendants()
			table.insert(all, thing)
			for _, d in ipairs(all) do
				if d:IsA("BasePart") or d:IsA("Decal") then -- Decal covers Texture too
					d.LocalTransparencyModifier = modifier
				end
			end
		end
	end
end

local showing = false
local savedCFrame, savedType

local function open()
	showing, sent = true, false
	root.Visible = true
	row.Visible, countdown.Visible, heading.Visible, confirm.Visible = true, true, true, false
	local camera = workspace.CurrentCamera
	savedCFrame, savedType = camera.CFrame, camera.CameraType
	camera.CameraType = Enum.CameraType.Scriptable
	local center = cabinet:WaitForChild("Floor").Position
	TweenService:Create(camera, FLY, { CFrame = CFrame.lookAt(center + SHOT_FROM, center + SHOT_AT) }):Play()
	setVistaHidden(true)
end

local function close()
	showing = false
	root.Visible = false
	setVistaHidden(false)
	local camera = workspace.CurrentCamera
	local back = TweenService:Create(camera, RETURN, { CFrame = savedCFrame })
	back.Completed:Connect(function()
		if not showing then
			camera.CameraType = savedType or Enum.CameraType.Custom
		end
	end)
	back:Play()
end

patternUI.OnClientEvent:Connect(function(p)
	local choosing = p.state == "ModeSelect" and p.chooserUserId == localPlayer.UserId
	if choosing and not showing then
		open()
	elseif not choosing and showing then
		close()
	end
	if not choosing then
		return
	end
	if p.confirming then
		row.Visible, countdown.Visible, heading.Visible = false, false, false
		confirm.Text = string.upper(p.mode or "") .. " MODE"
		confirm.Visible = true
	else
		countdown.Text = string.format("Auto-picks EASY in %d", p.timeLeft or 0)
	end
end)
