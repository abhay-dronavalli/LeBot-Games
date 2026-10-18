-- ReplicatedStorage.Core.Views.FloodRobotView
-- Rising Flood's robot view (Core.Games.Flood): what the operator at the real arm sees during a round.
--   * The chamber from overhead: Workspace.FloodArena (cloned in by the Flood mode, so it is waited for) seen
--     by a Scriptable camera high over its Floor, looking down at it. The shot is fitted each time the
--     screen, the map or the chamber changes, so the whole floor fits beside the map (FloodRobotView.frame).
--   * A big path map on the left: the 3x4 grid sheet (rows A-C, row A on the arm's side at the top,
--     columns 1-4), this round's path with numbered stops; done squares green, the next one pulsing yellow
--     (ReplicatedStorage.Flood "Path" and "Progress"; same colors as FloodClient's map). It shows while
--     ReplicatedStorage.Flood "RobotSeesPath" is not false (nil counts as true); when it is false the next
--     square is not named anywhere on this screen.
--   * The round state and timer at the top (Flood "State", "Countdown", "TimeLeft", "RoundTime",
--     "Difficulty", "Message").
-- enter(ctx) / exit(): exit disconnects everything, destroys the GUI and puts the camera back. Never
-- touches Lighting.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Flood = ReplicatedStorage:WaitForChild("Flood")

local ROWS, COLS, GRACE_TIME = { "A", "B", "C" }, 4, 5
do
	local ok, config = pcall(function()
		return require(Flood:WaitForChild("FloodConfig", 5))
	end)
	if ok and type(config) == "table" then
		if config.GRID then
			ROWS, COLS = config.GRID.rows or ROWS, config.GRID.cols or COLS
		end
		GRACE_TIME = config.GRACE_TIME or GRACE_TIME
	end
end

-- Camera: an eye over the floor (EYE_HEIGHT studs up, or CEILING_GAP under the ceiling; at least WALL_GAP
-- in from the walls), looking down at the floor. FloodRobotView.frame picks the eye spot and aim point
-- that fit the whole floor into the screen part beside the map with the smallest field of view.
local EYE_HEIGHT = 58
local CEILING_GAP = 5
local WALL_GAP = 6
local EYE_STEP = 4 -- studs between the eye spots tried
local AIM_OFFSETS = { -10, -5, 0, 5, 10 } -- aim points tried, studs from below the eye (x) / the center (z)
local CEILING_PROBE = 52 -- the ceiling is looked for from this high over the floor, above the tallest tower
local EYE_CLEARANCE = 4 -- studs kept between the eye and anything hanging in the chamber (the Sewer arm)
local FIT_MARGIN = 0.04 -- screen space (-1..1) kept clear around the floor
local FOV_MIN, FOV_MAX = 30, 110

local PANEL = Color3.fromRGB(20, 24, 32)
local CELL = Color3.fromRGB(40, 46, 58)
local CELL_STROKE = Color3.fromRGB(90, 98, 112)
local CELL_NAME = Color3.fromRGB(120, 130, 145)
local CELL_DONE = Color3.fromRGB(40, 90, 55)
local CELL_NEXT = Color3.fromRGB(150, 120, 30)
local GREEN = Color3.fromRGB(90, 220, 110)
local YELLOW = Color3.fromRGB(255, 210, 60)
local IDLE = Color3.fromRGB(150, 158, 172)
local MUTED = Color3.fromRGB(150, 160, 175)
local RED = Color3.fromRGB(255, 120, 120)

local FloodRobotView = {}

local connections = {}
local gui
local savedCamera

------------------------------------------------------------------ pure helpers

-- "A1,A2,B2" -> { "A1", "A2", "B2" }
function FloodRobotView.parsePath(path)
	local cells = {}
	for name in tostring(path or ""):gmatch("[^,%s]+") do
		table.insert(cells, name)
	end
	return cells
end

-- Row and column (1-based) of a cell name like "B3", or nil.
function FloodRobotView.cellPos(name)
	local r = table.find(ROWS, name:sub(1, 1))
	local c = tonumber(name:sub(2))
	if r and c and c >= 1 and c <= COLS then
		return r, c
	end
	return nil
end

-- The smallest vertical FOV (FOV_MIN..upTo) at which camera `cf` shows every point inside `rect` (screen
-- space -1..1: left, right, bottom, top) on a viewport `aspect` (width / height) wide, or nil.
function FloodRobotView.minFov(cf, points, aspect, rect, upTo)
	local function fits(fov)
		local tv = math.tan(math.rad(fov) / 2)
		local th = tv * aspect
		for _, p in ipairs(points) do
			local l = cf:PointToObjectSpace(p)
			if l.Z > -0.1 then
				return false
			end
			local x, y = l.X / -l.Z / th, l.Y / -l.Z / tv
			if x < rect.left or x > rect.right or y < rect.bottom or y > rect.top then
				return false
			end
		end
		return true
	end
	if upTo < FOV_MIN or not fits(upTo) then
		return nil
	end
	local lo, hi = FOV_MIN, upTo
	while lo < hi do
		local mid = (lo + hi) // 2
		if fits(mid) then
			hi = mid
		else
			lo = mid + 1
		end
	end
	return lo
end

-- The overhead shot of a chamber floor (an axis-aligned part): tries eye spots over the floor and aim
-- points near it, and keeps the camera that fits all four corners of the floor's top into `rect` with the
-- smallest field of view. ceilingAt(x, z) -> the ceiling's y there, or nil; blocked(eye) -> true to skip
-- an eye spot (optional). Returns cframe, fov.
function FloodRobotView.frame(floorCFrame, floorSize, ceilingAt, aspect, rect, blocked)
	local top = floorCFrame * Vector3.new(0, floorSize.Y / 2, 0)
	local points = {}
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			table.insert(points, floorCFrame * Vector3.new(sx * floorSize.X / 2, floorSize.Y / 2, sz * floorSize.Z / 2))
		end
	end
	local hx = math.max(floorSize.X / 2 - WALL_GAP, 0)
	local hz = math.max(floorSize.Z / 2 - WALL_GAP, 0)
	local bestCFrame, bestFov = nil, FOV_MAX + 1
	for ex = -hx, hx + 1e-3, EYE_STEP do
		for ez = -hz, hz + 1e-3, EYE_STEP do
			local eyeY = top.Y + EYE_HEIGHT
			local ceiling = ceilingAt(top.X + ex, top.Z + ez)
			if ceiling then
				eyeY = math.min(eyeY, ceiling - CEILING_GAP)
			end
			local eye = Vector3.new(top.X + ex, eyeY, top.Z + ez)
			for _, ax in ipairs(blocked and blocked(eye) and {} or AIM_OFFSETS) do
				for _, az in ipairs(AIM_OFFSETS) do
					local cf = CFrame.lookAt(eye, top + Vector3.new(ex + ax, 0, az))
					local fov = FloodRobotView.minFov(cf, points, aspect, rect, bestFov - 1)
					if fov then
						bestCFrame, bestFov = cf, fov
					end
				end
			end
		end
	end
	if bestCFrame then
		return bestCFrame, bestFov
	end
	-- nothing fits (a tiny screen): straight over the center, as wide as allowed
	return CFrame.lookAt(top + Vector3.new(0, EYE_HEIGHT, hz * 0.5), top), FOV_MAX
end

-- ceilingAt for FloodRobotView.frame: the first thing in the chamber above the tallest tower.
local function ceilingProbe(arena, floorTop)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { arena }
	return function(x, z)
		local hit = workspace:Raycast(Vector3.new(x, floorTop + CEILING_PROBE, z), Vector3.new(0, 200, 0), params)
		return hit and hit.Position.Y or nil
	end
end

-- blocked for FloodRobotView.frame: the eye would be in or next to a part high in the chamber (including
-- ones spatial queries skip, like the Sewer theme's arm).
local function hangingParts(arena, floorTop)
	local boxes = {}
	for _, part in ipairs(arena:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 1 then
			local cf, size = part.CFrame, part.Size
			local extent = Vector3.new(
				math.abs(cf.XVector.X) * size.X + math.abs(cf.YVector.X) * size.Y + math.abs(cf.ZVector.X) * size.Z,
				math.abs(cf.XVector.Y) * size.X + math.abs(cf.YVector.Y) * size.Y + math.abs(cf.ZVector.Y) * size.Z,
				math.abs(cf.XVector.Z) * size.X + math.abs(cf.YVector.Z) * size.Y + math.abs(cf.ZVector.Z) * size.Z
			) / 2 + Vector3.one * EYE_CLEARANCE
			if cf.Position.Y + extent.Y > floorTop + CEILING_PROBE then
				table.insert(boxes, { cf.Position - extent, cf.Position + extent })
			end
		end
	end
	return function(eye)
		for _, box in ipairs(boxes) do
			local lo, hi = box[1], box[2]
			if eye.X > lo.X and eye.X < hi.X and eye.Y > lo.Y and eye.Y < hi.Y and eye.Z > lo.Z and eye.Z < hi.Z then
				return true
			end
		end
		return false
	end
end

------------------------------------------------------------------ GUI

local function label(parent, name, props)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBlack
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.4
	l.TextScaled = true
	for k, v in pairs(props) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

local function panelLook(frame, radius)
	frame.BackgroundColor3 = PANEL
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, radius)
	local stroke = Instance.new("UIStroke", frame)
	stroke.Color = Color3.new(1, 1, 1)
	stroke.Transparency = 0.6
end

local function formatTime(sec)
	sec = math.max(0, math.ceil(sec))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function buildGui()
	local screen = Instance.new("ScreenGui")
	screen.Name = "FloodRobotStation"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 10

	-- top: round state and timer
	local bar = Instance.new("Frame")
	bar.Name = "StatusBar"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.new(0.5, 0, 0, 12)
	bar.Size = UDim2.new(0.5, 0, 0, 104)
	panelLook(bar, 10)
	bar.Parent = screen
	label(bar, "Game", { Position = UDim2.new(0, 0, 0, 6), Size = UDim2.new(1, 0, 0, 18), Font = Enum.Font.GothamBold,
		TextColor3 = MUTED, TextStrokeTransparency = 1, Text = "RISING FLOOD  ·  ROBOT" })
	local status = label(bar, "Status", { Position = UDim2.new(0, 12, 0, 26), Size = UDim2.new(1, -24, 0, 46), Text = "" })
	local detail = label(bar, "Detail", { Position = UDim2.new(0, 12, 0, 76), Size = UDim2.new(1, -24, 0, 22),
		Font = Enum.Font.GothamBold, Text = "" })

	-- left: the path map (the panel is square: title + a 4:3 grid)
	local panel = Instance.new("Frame")
	panel.Name = "PathMap"
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 24, 0.5, 58)
	panel.Size = UDim2.new(0.36, 0, 1, -164)
	panelLook(panel, 12)
	panel.Parent = screen
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = panel
	local mapTitle = label(panel, "Title", { Position = UDim2.fromScale(0.04, 0.03), Size = UDim2.fromScale(0.92, 0.12),
		TextXAlignment = Enum.TextXAlignment.Left, Text = "MOVE THE BLOCK" })
	local mapSteps = label(panel, "Steps", { Position = UDim2.fromScale(0.04, 0.16), Size = UDim2.fromScale(0.55, 0.055),
		Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	label(panel, "ArmSide", { Position = UDim2.fromScale(0.56, 0.16), Size = UDim2.fromScale(0.4, 0.055),
		Font = Enum.Font.GothamBold, TextColor3 = MUTED, TextStrokeTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Right, Text = "ARM SIDE ▲" })
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromScale(0.04, 0.245)
	grid.Size = UDim2.fromScale(0.92, 0.69)
	grid.Parent = panel
	local gridAspect = Instance.new("UIAspectRatioConstraint")
	gridAspect.AspectRatio = COLS / #ROWS
	gridAspect.Parent = grid

	local cells = {}
	for r, rowName in ipairs(ROWS) do
		for c = 1, COLS do
			local name = rowName .. c
			local cell = Instance.new("Frame")
			cell.Name = name
			cell.Position = UDim2.fromScale((c - 1) / COLS, (r - 1) / #ROWS)
			cell.Size = UDim2.fromScale(1 / COLS, 1 / #ROWS)
			cell.BackgroundColor3 = CELL
			cell.BorderSizePixel = 0
			cell.Parent = grid
			local stroke = Instance.new("UIStroke", cell)
			stroke.Color = CELL_STROKE
			stroke.Thickness = 2
			label(cell, "CellName", { Position = UDim2.fromScale(0.06, 0.04), Size = UDim2.fromScale(0.34, 0.24),
				Font = Enum.Font.GothamBold, TextColor3 = CELL_NAME, TextStrokeTransparency = 1,
				TextXAlignment = Enum.TextXAlignment.Left, Text = name })
			cells[name] = cell
		end
	end

	return {
		screen = screen,
		bar = bar,
		status = status,
		detail = detail,
		panel = panel,
		mapTitle = mapTitle,
		mapSteps = mapSteps,
		grid = grid,
		cells = cells,
		pathKey = nil,
		pathCells = {},
		segments = {},
		dots = {},
	}
end

local function centerOf(name)
	local r, c = FloodRobotView.cellPos(name)
	if not r then
		return nil
	end
	return Vector2.new((c - 0.5) / COLS, (r - 0.5) / #ROWS)
end

-- A straight bar between two cell centers (grid scale); a diagonal step gets an L of two bars.
local function addBar(ui, a, b)
	local seg = Instance.new("Frame")
	seg.AnchorPoint = Vector2.new(0.5, 0.5)
	seg.Position = UDim2.fromScale((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	if math.abs(a.Y - b.Y) < 1e-6 then
		seg.Size = UDim2.fromScale(math.abs(b.X - a.X) + 0.1 / COLS, 0.1 / #ROWS)
	else
		seg.Size = UDim2.fromScale(0.1 / COLS, math.abs(b.Y - a.Y) + 0.1 / #ROWS)
	end
	seg.BorderSizePixel = 0
	seg.ZIndex = 2
	seg.Parent = ui.grid
	return seg
end

local function buildPath(ui, cells)
	for _, list in ipairs({ ui.segments, ui.dots }) do
		for _, parts in ipairs(list) do
			for _, f in ipairs(type(parts) == "table" and parts or { parts }) do
				f:Destroy()
			end
		end
	end
	ui.pathCells, ui.segments, ui.dots = cells, {}, {}
	for i = 1, #cells - 1 do
		local a, b = centerOf(cells[i]), centerOf(cells[i + 1])
		local parts = {}
		if a and b then
			if math.abs(a.X - b.X) > 1e-6 and math.abs(a.Y - b.Y) > 1e-6 then
				local corner = Vector2.new(b.X, a.Y)
				table.insert(parts, addBar(ui, a, corner))
				table.insert(parts, addBar(ui, corner, b))
			else
				table.insert(parts, addBar(ui, a, b))
			end
		end
		ui.segments[i] = parts
	end
	for i, name in ipairs(cells) do
		local p = centerOf(name)
		if p then
			local dot = label(ui.grid, "Stop" .. i, {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(p.X, p.Y),
				Size = UDim2.fromScale(0.46 / COLS, 0.46 / #ROWS),
				BackgroundTransparency = 0,
				BackgroundColor3 = IDLE,
				BorderSizePixel = 0,
				TextColor3 = PANEL,
				TextStrokeTransparency = 1,
				Text = tostring(i),
				ZIndex = 3,
			})
			Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
			local pad = Instance.new("UIPadding", dot)
			pad.PaddingTop, pad.PaddingBottom = UDim.new(0.14, 0), UDim.new(0.14, 0)
			ui.dots[i] = dot
		end
	end
end

local function updateMap(ui, progress)
	local cells = ui.pathCells
	local pulse = (math.sin(os.clock() * 6) + 1) / 2
	for name, cell in pairs(ui.cells) do
		local i = table.find(cells, name)
		if i and i <= progress then
			cell.BackgroundColor3 = CELL_DONE
		elseif i and i == progress + 1 then
			cell.BackgroundColor3 = CELL:Lerp(CELL_NEXT, pulse)
		else
			cell.BackgroundColor3 = CELL
		end
	end
	for i, parts in pairs(ui.segments) do
		local color = if progress >= i + 1 then GREEN elseif progress == i then YELLOW else IDLE
		for _, seg in ipairs(parts) do
			seg.BackgroundColor3 = color
		end
	end
	for i, dot in pairs(ui.dots) do
		dot.BackgroundColor3 = if i <= progress then GREEN elseif i == progress + 1 then IDLE:Lerp(YELLOW, pulse) else IDLE
	end
	if #cells == 0 then
		ui.mapTitle.Text = "MOVE THE BLOCK"
		ui.mapSteps.Text = ""
	elseif progress >= #cells then
		ui.mapTitle.Text = "PATH DONE!"
		ui.mapSteps.Text = string.format("%d / %d squares", #cells, #cells)
	else
		ui.mapTitle.Text = "NEXT: " .. cells[progress + 1]
		ui.mapSteps.Text = string.format("%d / %d squares", progress, #cells)
	end
end

local function updateStatus(ui, showPath, hasArena)
	local state = Flood:GetAttribute("State")
	local cells = ui.pathCells
	local progress = Flood:GetAttribute("Progress") or 0
	local roundTime = Flood:GetAttribute("RoundTime") or 60
	local timeLeft = Flood:GetAttribute("TimeLeft") or roundTime
	local difficulty = tostring(Flood:GetAttribute("Difficulty") or ""):upper()
	local steps = string.format("%d/%d squares", math.min(progress, #cells), #cells)
	ui.status.TextColor3 = Color3.new(1, 1, 1)
	if not hasArena then
		ui.status.Text = "RISING FLOOD"
		ui.detail.Text = "Loading the chamber..."
	elseif state == "Countdown" then
		ui.status.Text = "GET READY  " .. tostring(Flood:GetAttribute("Countdown") or "")
		ui.detail.Text = string.format("%s: %d squares", difficulty, #cells)
	elseif state == "Running" then
		ui.status.Text = formatTime(timeLeft)
		if timeLeft <= 10 then
			ui.status.TextColor3 = RED
		end
		local elapsed = roundTime - timeLeft
		if progress >= #cells and #cells > 0 then
			ui.detail.Text = "Path done!"
		elseif not showPath then
			ui.detail.Text = "Follow your partner's directions  ·  " .. steps
		elseif elapsed < GRACE_TIME then
			ui.detail.Text = string.format("Water rises in %d...  ·  move the block to %s", math.ceil(GRACE_TIME - elapsed),
				cells[progress + 1] or "?")
		else
			ui.detail.Text = string.format("Move the block to %s  ·  %s", cells[progress + 1] or "?", steps)
		end
	elseif state == "Won" then
		ui.status.Text = if Flood:GetAttribute("Message") == "Escaped" then "ESCAPED!" else "SURVIVED!"
		ui.detail.Text = "Heading back to the workshop..."
	elseif state == "Lost" then
		ui.status.Text = "FLOODED"
		ui.detail.Text = "Heading back to the workshop..."
	else
		ui.status.Text = "RISING FLOOD"
		ui.detail.Text = "Starting..."
	end
end

------------------------------------------------------------------ view

local function pathShown()
	return Flood:GetAttribute("RobotSeesPath") ~= false
end

function FloodRobotView.enter()
	FloodRobotView.exit()
	local camera = workspace.CurrentCamera
	savedCamera = { camera = camera, type = camera.CameraType, cframe = camera.CFrame, fov = camera.FieldOfView }

	local ui = buildGui()
	gui = ui.screen
	ui.panel.Visible = pathShown()
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local arena, floor
	local shotCFrame, shotFov
	local fitKey

	-- the screen part left for the chamber: right of the map (if shown), below the status bar
	local function screenRect(viewport)
		local left = -1
		if ui.panel.Visible then
			left = math.min((ui.panel.AbsolutePosition.X + ui.panel.AbsoluteSize.X + 12) / viewport.X * 2 - 1, 0.2)
		end
		local top = math.max(1 - (ui.bar.AbsolutePosition.Y + ui.bar.AbsoluteSize.Y + 8) / viewport.Y * 2, 0)
		return { left = left + FIT_MARGIN, right = 1 - FIT_MARGIN, bottom = -1 + FIT_MARGIN, top = top - FIT_MARGIN }
	end

	table.insert(connections, Flood:GetAttributeChangedSignal("RobotSeesPath"):Connect(function()
		ui.panel.Visible = pathShown()
	end))

	-- HUD: Heartbeat, so it keeps updating while Studio is unfocused (like FloodClient)
	table.insert(connections, RunService.Heartbeat:Connect(function()
		local path = Flood:GetAttribute("Path") or ""
		if path ~= ui.pathKey then
			ui.pathKey = path
			buildPath(ui, FloodRobotView.parsePath(path))
		end
		local showPath = pathShown()
		if showPath then
			updateMap(ui, Flood:GetAttribute("Progress") or 0)
		end
		updateStatus(ui, showPath, floor ~= nil)
	end))

	-- Camera: wait for the chamber (cloned in by the mode, then streamed), fit once per layout.
	table.insert(connections, RunService.RenderStepped:Connect(function()
		local current = workspace:FindFirstChild("FloodArena")
		if current ~= arena then
			arena, floor, fitKey = current, nil, nil
		end
		if arena and not (floor and floor.Parent) then
			local f = arena:FindFirstChild("Floor")
			floor = if f and f:IsA("BasePart") then f else nil
			fitKey = nil
		end
		if not floor then
			return -- keep the last shot until the chamber is here
		end
		local cam = workspace.CurrentCamera
		local viewport = cam.ViewportSize
		local key = string.format("%d,%d,%s,%d,%d,%s", viewport.X, viewport.Y, tostring(ui.panel.Visible),
			ui.panel.AbsoluteSize.X, ui.bar.AbsoluteSize.Y, tostring(floor.CFrame.Position))
		if key ~= fitKey and viewport.Y > 0 then
			fitKey = key
			local floorTop = floor.Position.Y + floor.Size.Y / 2
			shotCFrame, shotFov = FloodRobotView.frame(floor.CFrame, floor.Size, ceilingProbe(arena, floorTop),
				viewport.X / viewport.Y, screenRect(viewport), hangingParts(arena, floorTop))
		end
		if shotCFrame then
			cam.CameraType = Enum.CameraType.Scriptable
			cam.CFrame = shotCFrame
			cam.FieldOfView = shotFov
		end
	end))
end

function FloodRobotView.exit()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if gui then
		gui:Destroy()
		gui = nil
	end
	if savedCamera then
		local camera = savedCamera.camera
		if camera and camera.Parent then
			camera.FieldOfView = savedCamera.fov
			camera.CameraType = savedCamera.type
			camera.CFrame = savedCamera.cframe
		end
		savedCamera = nil
	end
end

return FloodRobotView
