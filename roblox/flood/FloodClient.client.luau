-- Studio location: StarterPlayer.StarterPlayerScripts.FloodClient (LocalScript)
-- Rising Flood HUD, effects and Studio mock controls.
-- Only shows while Flood is running and the local player is inside the chamber.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Flood = ReplicatedStorage:WaitForChild("Flood")
local Config = require(Flood:WaitForChild("FloodConfig"))
local debugRemote = Flood:WaitForChild("FloodDebug")
local fxRemote = Flood:WaitForChild("FloodFx")

local GAUGE_PX = 220
local GAUGE_TOP = 212 -- just below the path map (16 + its 182 px height + a gap)
-- tower size for the current round (from the Flood attributes when a round starts)
local roundTarget, roundStep, roundTime = Config.TARGET_STEPS, Config.STEP_HEIGHT, Config.ROUND_TIME
local gaugeStuds = roundTarget * roundStep + 4

-- the chamber is cloned in by the Flood mode, so look it up whenever it changes
local arena, floor, floorY, half
local sprays, beacons = {}, {}
-- per-theme look, from the map's Settings (defaults = the Water theme)
local underTint, underSaturation, underBlur, stayText

local function bindArena(a)
	arena = a
	sprays, beacons = {}, {}
	if not a then
		return
	end
	floor = a:WaitForChild("Floor")
	floorY = floor.Position.Y + floor.Size.Y / 2
	half = floor.Size.X / 2
	local pipes = a:FindFirstChild("Pipes")
	if pipes then
		for _, d in pipes:GetDescendants() do
			if d:IsA("ParticleEmitter") and d.Name == "Spray" then
				table.insert(sprays, d)
			end
		end
	end
	local alarms = a:FindFirstChild("Alarms")
	if alarms then
		for _, d in alarms:GetChildren() do
			if d.Name == "Beacon" then
				table.insert(beacons, d)
			end
		end
	end
	local settings = a:FindFirstChild("Settings")
	local function setting(name, default)
		local v = settings and settings:GetAttribute(name)
		return if v == nil then default else v
	end
	underTint = setting("UnderTint", Color3.fromRGB(120, 180, 255))
	underSaturation = setting("UnderSaturation", -0.2)
	underBlur = setting("UnderBlur", 0)
	stayText = setting("StayText", "Climb the tower! Stay above the water!")
end

------------------------------------------------------------------ GUI

local gui = Instance.new("ScreenGui")
gui.Name = "FloodHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local function label(props)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.4
	t.TextScaled = true
	for k, v in props do
		t[k] = v
	end
	t.Parent = props.Parent or gui
	return t
end

local title = label({
	Name = "Title",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 52),
	Size = UDim2.new(0.6, 0, 0, 44),
})
local subtitle = label({
	Name = "Subtitle",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 98),
	Size = UDim2.new(0.6, 0, 0, 24),
	Font = Enum.Font.GothamBold,
})
local banner = label({
	Name = "Banner",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.4),
	Size = UDim2.fromScale(0.7, 0.14),
	TextTransparency = 1,
	TextStrokeTransparency = 1,
})

-- Gauge: tower steps, water level, target line and the player's height.
local gauge = Instance.new("Frame")
gauge.Name = "Gauge"
gauge.AnchorPoint = Vector2.new(1, 0)
gauge.Position = UDim2.new(1, -24, 0, GAUGE_TOP)
gauge.Size = UDim2.fromOffset(46, GAUGE_PX)
gauge.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
gauge.BackgroundTransparency = 0.25
gauge.Parent = gui
Instance.new("UICorner", gauge).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", gauge)
stroke.Color = Color3.fromRGB(255, 255, 255)
stroke.Transparency = 0.6

local function studsToPx(studs)
	return math.clamp(studs / gaugeStuds, 0, 1) * GAUGE_PX
end

local stepBars = {}
for k = 1, Config.MAX_STEPS do
	local b = Instance.new("Frame")
	b.Name = "Step" .. k
	b.AnchorPoint = Vector2.new(0.5, 1)
	b.BackgroundColor3 = Config.BLOCK_COLORS[(k - 1) % #Config.BLOCK_COLORS + 1]
	b.BorderSizePixel = 0
	b.Visible = false
	b.Parent = gauge
	stepBars[k] = b
end

local waterFill = Instance.new("Frame")
waterFill.Name = "Water"
waterFill.AnchorPoint = Vector2.new(0, 1)
waterFill.Position = UDim2.fromScale(0, 1)
waterFill.Size = UDim2.new(1, 0, 0, 0)
waterFill.BackgroundColor3 = Color3.fromRGB(40, 140, 230)
waterFill.BackgroundTransparency = 0.35
waterFill.BorderSizePixel = 0
waterFill.ZIndex = 2
waterFill.Parent = gauge

local targetLine = Instance.new("Frame")
targetLine.Name = "Target"
targetLine.AnchorPoint = Vector2.new(0, 0.5)
targetLine.Size = UDim2.new(1, 0, 0, 2)
targetLine.BackgroundColor3 = Color3.fromRGB(255, 210, 60)
targetLine.BorderSizePixel = 0
targetLine.ZIndex = 3
targetLine.Parent = gauge

local youMarker = label({
	Name = "You",
	Parent = gauge,
	AnchorPoint = Vector2.new(0, 0.5),
	Size = UDim2.fromOffset(46, 14),
	Text = "YOU >",
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 4,
})

local gaugeCaption = label({
	Name = "GaugeCaption",
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -16, 0, GAUGE_TOP + GAUGE_PX + 8),
	Size = UDim2.fromOffset(110, 20),
	Font = Enum.Font.GothamBold,
})

local function layoutGauge()
	gaugeStuds = roundTarget * roundStep + 4
	for k, b in stepBars do
		b.Position = UDim2.new(0.5, 0, 1, -studsToPx((k - 1) * roundStep))
		b.Size = UDim2.new(0.5, 0, 0, math.max(studsToPx(roundStep) - 2, 1))
	end
	targetLine.Position = UDim2.new(0, 0, 1, -studsToPx(roundTarget * roundStep))
end
layoutGauge()

-- Path map (top right): the 3x4 grid sheet as the operator sees it (row A, the arm's side, at
-- the top), with this round's path. Done squares turn green and the next one pulses yellow.
local MAP_CELL = 44
local GRID_ROWS = Config.GRID.rows
local mapPanel = Instance.new("Frame")
mapPanel.Name = "PathMap"
mapPanel.AnchorPoint = Vector2.new(1, 0)
mapPanel.Position = UDim2.new(1, -16, 0, 16)
mapPanel.Size = UDim2.fromOffset(MAP_CELL * Config.GRID.cols + 24, MAP_CELL * #GRID_ROWS + 50)
mapPanel.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
mapPanel.BackgroundTransparency = 0.2
mapPanel.Parent = gui
Instance.new("UICorner", mapPanel).CornerRadius = UDim.new(0, 8)
local mapStroke = Instance.new("UIStroke", mapPanel)
mapStroke.Color = Color3.fromRGB(255, 255, 255)
mapStroke.Transparency = 0.6
local mapTitle = label({
	Name = "Title",
	Parent = mapPanel,
	Position = UDim2.fromOffset(12, 6),
	Size = UDim2.new(1, -24, 0, 18),
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "MOVE THE BLOCK",
})
label({
	Name = "ArmSide",
	Parent = mapPanel,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 30),
	Size = UDim2.fromOffset(80, 10),
	Font = Enum.Font.GothamBold,
	TextColor3 = Color3.fromRGB(150, 160, 175),
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "ARM SIDE",
})
local mapGrid = Instance.new("Frame")
mapGrid.Name = "Grid"
mapGrid.BackgroundTransparency = 1
mapGrid.Position = UDim2.fromOffset(12, 42)
mapGrid.Size = UDim2.fromOffset(MAP_CELL * Config.GRID.cols, MAP_CELL * #GRID_ROWS)
mapGrid.Parent = mapPanel
local mapCells = {}
for r, rowName in GRID_ROWS do
	for c = 1, Config.GRID.cols do
		local name = rowName .. c
		local cell = Instance.new("Frame")
		cell.Name = name
		cell.Position = UDim2.fromOffset((c - 1) * MAP_CELL, (r - 1) * MAP_CELL)
		cell.Size = UDim2.fromOffset(MAP_CELL, MAP_CELL)
		cell.BackgroundColor3 = Color3.fromRGB(40, 46, 58)
		cell.BorderSizePixel = 0
		cell.Parent = mapGrid
		local cs = Instance.new("UIStroke", cell)
		cs.Color = Color3.fromRGB(90, 98, 112)
		cs.Thickness = 1
		label({
			Name = "CellName",
			Parent = cell,
			Position = UDim2.fromOffset(3, 2),
			Size = UDim2.fromOffset(18, 10),
			Font = Enum.Font.GothamBold,
			TextColor3 = Color3.fromRGB(120, 130, 145),
			TextStrokeTransparency = 1,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = name,
		})
		mapCells[name] = cell
	end
end
local pathCells, pathSegments, pathDots = {}, {}, {}

local function cellCenter(name)
	local r = table.find(GRID_ROWS, name:sub(1, 1)) or 1
	local c = tonumber(name:sub(2)) or 1
	return Vector2.new((c - 0.5) * MAP_CELL, (r - 0.5) * MAP_CELL)
end

local function buildPathMap(cells)
	for _, f in pathSegments do
		f:Destroy()
	end
	for _, f in pathDots do
		f:Destroy()
	end
	pathCells, pathSegments, pathDots = cells, {}, {}
	for i = 1, #cells - 1 do
		local a, b = cellCenter(cells[i]), cellCenter(cells[i + 1])
		local seg = Instance.new("Frame")
		seg.Name = "Segment" .. i
		seg.AnchorPoint = Vector2.new(0.5, 0.5)
		seg.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
		seg.Size = UDim2.fromOffset((b - a).Magnitude, 5)
		seg.Rotation = math.deg(math.atan2(b.Y - a.Y, b.X - a.X))
		seg.BorderSizePixel = 0
		seg.ZIndex = 2
		seg.Parent = mapGrid
		pathSegments[i] = seg
	end
	for i, name in cells do
		local p = cellCenter(name)
		local dot = Instance.new("TextLabel")
		dot.Name = "Stop" .. i
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromOffset(p.X, p.Y)
		dot.Size = UDim2.fromOffset(20, 20)
		dot.Font = Enum.Font.GothamBlack
		dot.TextScaled = true
		dot.Text = tostring(i)
		dot.TextColor3 = Color3.fromRGB(20, 24, 32)
		dot.BorderSizePixel = 0
		dot.ZIndex = 3
		dot.Parent = mapGrid
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		pathDots[i] = dot
	end
end

local function updatePathMap(progress)
	local pulse = (math.sin(os.clock() * 6) + 1) / 2
	local GREEN = Color3.fromRGB(90, 220, 110)
	local YELLOW = Color3.fromRGB(255, 210, 60)
	local IDLE = Color3.fromRGB(150, 158, 172)
	for name, cell in mapCells do
		local i = table.find(pathCells, name)
		if i and i <= progress then
			cell.BackgroundColor3 = Color3.fromRGB(40, 90, 55)
		elseif i and i == progress + 1 then
			cell.BackgroundColor3 = Color3.fromRGB(40, 46, 58):Lerp(Color3.fromRGB(150, 120, 30), pulse)
		else
			cell.BackgroundColor3 = Color3.fromRGB(40, 46, 58)
		end
	end
	for i, seg in pathSegments do
		seg.BackgroundColor3 = if progress >= i + 1 then GREEN elseif progress == i then YELLOW else IDLE
	end
	for i, dot in pathDots do
		dot.BackgroundColor3 = if i <= progress then GREEN elseif i == progress + 1 then IDLE:Lerp(YELLOW, pulse) else IDLE
	end
	if #pathCells == 0 then
		mapTitle.Text = "MOVE THE BLOCK"
	elseif progress >= #pathCells then
		mapTitle.Text = "PATH DONE!"
	else
		mapTitle.Text = string.format("NEXT: %s   %d/%d", pathCells[progress + 1], progress, #pathCells)
	end
end

local function loadRound()
	roundTarget = Flood:GetAttribute("TargetSteps") or Config.TARGET_STEPS
	roundStep = Flood:GetAttribute("StepHeight") or Config.STEP_HEIGHT
	roundTime = Flood:GetAttribute("RoundTime") or Config.ROUND_TIME
	layoutGauge()
	local path = Flood:GetAttribute("Path") or ""
	local cells = {}
	for name in path:gmatch("[^,]+") do
		table.insert(cells, name)
	end
	buildPathMap(cells)
end

if RunService:IsStudio() then
	label({
		Name = "MockHint",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.fromOffset(460, 20),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTransparency = 0.25,
		Text = "MOCK  [B] block reached next square   [N] step back   [C] clear",
	})
end

------------------------------------------------------------------ effects

local underwater = Instance.new("ColorCorrectionEffect")
underwater.Name = "FloodUnderwater"
underwater.TintColor = Color3.fromRGB(120, 180, 255)
underwater.Saturation = -0.2
underwater.Enabled = false
underwater.Parent = Lighting

local underwaterBlur = Instance.new("BlurEffect")
underwaterBlur.Name = "FloodUnderwaterBlur"
underwaterBlur.Size = 0
underwaterBlur.Enabled = false
underwaterBlur.Parent = Lighting

local function showBanner(text, color, duration)
	banner.Text = text
	banner.TextColor3 = color
	banner.TextTransparency = 0
	banner.TextStrokeTransparency = 0.3
	local token = {}
	banner:SetAttribute("Token", tostring(token))
	task.delay(duration, function()
		if banner:GetAttribute("Token") == tostring(token) then
			TweenService:Create(banner, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

local shakeUntil, shakeAmp = 0, 0

fxRemote.OnClientEvent:Connect(function(kind, arg)
	if not gui.Enabled then
		return
	end
	if kind == "surge" then
		showBanner("TOWER COLLAPSED! WATER SURGE!", Color3.fromRGB(255, 90, 90), 2.5)
		shakeUntil, shakeAmp = os.clock() + Config.SURGE_DURATION, 0.6
	elseif kind == "flooded" then
		if arg == player.DisplayName then
			showBanner("YOU GOT FLOODED!", Color3.fromRGB(120, 190, 255), 2.5)
		else
			showBanner(arg .. " got flooded!", Color3.fromRGB(120, 190, 255), 2)
		end
	elseif kind == "escaped" then
		if player:GetAttribute("Flooded") then
			showBanner("THE OTHERS ESCAPED!", Color3.fromRGB(120, 190, 255), Config.RESULT_TIME)
		else
			showBanner("YOU ESCAPED THE FLOOD!", Color3.fromRGB(255, 220, 80), Config.RESULT_TIME)
		end
	elseif kind == "won" then
		showBanner("YOU SURVIVED THE FLOOD!", Color3.fromRGB(255, 220, 80), Config.RESULT_TIME)
	elseif kind == "lost" then
		showBanner("FLOODED! GAME OVER", Color3.fromRGB(120, 190, 255), Config.RESULT_TIME)
	end
end)

------------------------------------------------------------------ mock input

if RunService:IsStudio() then
	local keys = {
		[Enum.KeyCode.B] = "add",
		[Enum.KeyCode.N] = "remove",
		[Enum.KeyCode.C] = "clear",
	}
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and gui.Enabled and keys[input.KeyCode] then
			debugRemote:FireServer(keys[input.KeyCode])
		end
	end)
end

------------------------------------------------------------------ per frame

local function formatTime(sec)
	sec = math.ceil(sec)
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function setPlayerList(on)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, on)
	end)
end

local function deactivate(hum)
	gui.Enabled = false
	underwater.Enabled = false
	underwaterBlur.Enabled = false
	if hum and hum.CameraOffset ~= Vector3.zero then
		hum.CameraOffset = Vector3.zero
	end
	setPlayerList(true) -- the gauge covers the player list, so it's hidden only in Flood
end

-- optional per-theme client module: ReplicatedStorage.Flood.Themes.<map's Theme attribute>
local themeFolder = Flood:WaitForChild("Themes", 5)
local themeClient

-- Heartbeat rather than RenderStepped so the HUD keeps updating while Studio is unfocused.
RunService.Heartbeat:Connect(function(dt)
	local current = workspace:FindFirstChild("FloodArena")
	if current ~= arena then
		if themeClient then
			themeClient.unbind()
			themeClient = nil
		end
		bindArena(current)
		if current then
			loadRound()
		end
		local themeName = current and current:GetAttribute("Theme")
		local mod = themeName and themeFolder and themeFolder:FindFirstChild(themeName)
		if mod and mod:IsA("ModuleScript") then
			themeClient = require(mod)
			themeClient.bind(current, { showBanner = showBanner })
		end
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local inside = false
	if arena and hrp and Flood:GetAttribute("Active") then
		local d = hrp.Position - floor.Position
		inside = math.abs(d.X) < half and math.abs(d.Z) < half
	end
	if themeClient then
		themeClient.update(dt, {
			inside = inside,
			level = Flood:GetAttribute("WaterLevel") or 0,
			floorY = floorY,
			timeLeft = Flood:GetAttribute("TimeLeft") or roundTime,
			roundTime = roundTime,
			state = Flood:GetAttribute("State") or "Countdown",
			hrp = hrp,
			hum = hum,
		})
	end
	if not inside then
		if gui.Enabled then
			deactivate(hum)
		end
		return
	end
	if not gui.Enabled then
		gui.Enabled = true
		setPlayerList(false)
	end

	local s = Flood:GetAttribute("State") or "Countdown"
	local h = Flood:GetAttribute("TowerHeight") or 0
	local level = Flood:GetAttribute("WaterLevel") or 0
	local timeLeft = Flood:GetAttribute("TimeLeft") or roundTime
	local isFlooded = player:GetAttribute("Flooded")
	local progress = Flood:GetAttribute("Progress") or 0
	if (Flood:GetAttribute("Path") or "") ~= table.concat(pathCells, ",") then
		loadRound() -- the path attribute replicated after the map did
	end
	updatePathMap(progress)

	title.TextColor3 = Color3.new(1, 1, 1)
	if s == "Countdown" then
		title.Text = tostring(Flood:GetAttribute("Countdown") or "")
		subtitle.Text = string.format("%s: %d squares. Get ready to climb!", tostring(Flood:GetAttribute("Difficulty") or ""):upper(), #pathCells)
	elseif s == "Running" then
		local elapsed = roundTime - timeLeft
		title.Text = "SURVIVE  " .. formatTime(timeLeft)
		if timeLeft <= 10 then
			title.TextColor3 = Color3.fromRGB(255, 120, 120)
		end
		if isFlooded then
			subtitle.Text = "You're waterlogged. Cheer on the others!"
		elseif elapsed < Config.GRACE_TIME then
			subtitle.Text = string.format("Water rises in %d...", math.ceil(Config.GRACE_TIME - elapsed))
		elseif progress < #pathCells then
			subtitle.Text = string.format("Move the block to %s  (%d/%d)", pathCells[progress + 1], progress, #pathCells)
		else
			subtitle.Text = stayText
		end
	elseif s == "Won" then
		title.Text = if Flood:GetAttribute("Message") == "Escaped" then "ESCAPED!" else "VICTORY"
		subtitle.Text = "Heading back to the arcade..."
	elseif s == "Lost" then
		title.Text = "FLOODED"
		subtitle.Text = "Heading back to the arcade..."
	end

	-- gauge
	for k, b in stepBars do
		b.Visible = k <= h
	end
	waterFill.Size = UDim2.new(1, 0, 0, studsToPx(math.max(0, level)))
	gaugeCaption.Text = string.format("TOWER %d / %d", h, roundTarget)

	local feet = hrp.Position.Y - hum.HipHeight - hrp.Size.Y / 2 - floorY
	youMarker.Position = UDim2.new(0, -2, 1, -math.max(studsToPx(feet), 7))
	if os.clock() < shakeUntil then
		local a = shakeAmp
		hum.CameraOffset = Vector3.new((math.random() - 0.5) * a, (math.random() - 0.5) * a, (math.random() - 0.5) * a)
	elseif hum.CameraOffset ~= Vector3.zero then
		hum.CameraOffset = Vector3.zero
	end

	-- pipes pour and alarms flash while the water is rising
	local rising = s == "Running" and roundTime - timeLeft >= Config.GRACE_TIME
	for _, pe in sprays do
		pe.Enabled = rising
	end
	local pulse = if rising then (math.sin(os.clock() * 8) + 1) / 2 else 0
	for _, b in beacons do
		b.PointLight.Brightness = pulse * 3
		b.Material = if pulse > 0.5 then Enum.Material.Neon else Enum.Material.Glass
		b.Color = Color3.fromRGB(120, 20, 20):Lerp(Color3.fromRGB(255, 60, 40), pulse)
	end

	-- underwater tint
	local cam = workspace.CurrentCamera.CFrame.Position
	local cd = cam - floor.Position
	local camUnder = level > 0 and math.abs(cd.X) < half and math.abs(cd.Z) < half and cam.Y < floorY + level
	underwater.TintColor = underTint
	underwater.Saturation = underSaturation
	underwater.Enabled = camUnder
	underwaterBlur.Size = underBlur
	underwaterBlur.Enabled = camUnder and underBlur > 0
end)
