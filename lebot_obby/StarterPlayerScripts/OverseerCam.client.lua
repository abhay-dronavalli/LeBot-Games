-- OverseerCam (client) -- player 2's view of the bay.
--
-- The overseer's job is to put real cubes on a real mat and have them land in the right cells.
-- That needs a view where the 4x3 grid is legible, the runner is findable, and the obstacle is
-- visible at the same time. The runner's over-the-shoulder camera is none of those.
--
-- **V** toggles it. In solo one person flips between the two halves of the game; with two
-- players, player 2 simply leaves it on.
--
-- WHY NEARLY TOP-DOWN. Steep enough that the grid reads as a grid -- at a shallower angle the
-- far row foreshortens and "col 2, row 2" becomes a guess -- but tilted a few degrees toward
-- the entrance so the room keeps its walls and some sense of depth.
--
-- WALLS. Two layers are in the way and both are handled CLIENT-SIDE, so this is one viewer's
-- x-ray and not a change to the world -- the runner still sees solid walls around them:
--   * the warehouse shell, which surrounds every bay
--   * the bay's OWN walls and ceiling. Bay 4 is the acute case: the dark room is roofed at
--     y = 14, so without this the overseer is looking at the top of a closed box.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Ui = require(ReplicatedStorage:WaitForChild("UiTheme"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DebugStatus = Remotes:WaitForChild("DebugStatus")
local DebugCommand = Remotes:WaitForChild("DebugCommand")
local BayCells = Remotes:WaitForChild("BayCells")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CELL = Config.CellSize
local HEIGHT = 62          -- steep: the grid has to read as a grid
local SETBACK = 9          -- a few degrees of tilt so the room keeps its walls

local INK = Ui.C.parchment
local WANT = Ui.C.amber        -- the cell being asked for RIGHT NOW
local HELD = Ui.C.ok           -- already filled
local RUNNER = Ui.C.info       -- where player 1 is standing
local DIMMED = Ui.C.ghost

local active = false
local activeBay = Config.LiveBay or 1

-- Camera the overseer can actually drive. A fixed shot is fine until you need to look at one
-- corner of the bay, which is most of the time once a run is underway.
--
-- PAN IS ON THE RIGHT MOUSE BUTTON, not on keys. Every key that reads as "move the view" --
-- WASD and the arrows alike -- is already a key that WALKS THE RUNNER, and in solo the
-- overseer and the runner are the same person. Panning with the arrows marched the character
-- out of the bay while the operator thought they were looking around.
local zoom, panX, panZ = 1, 0, 0
local ZOOM_MIN, ZOOM_MAX = 0.45, 2.3
local PAN_LIMIT = 26        -- studs from the bay centre; past that the bay leaves the screen
local PAN_PER_PIXEL = 0.09
local panning = false

-- X-ray is a toggle, not a fixture. Sometimes you want to see the room as the runner sees it
-- -- walls, roof and all -- and then put them back.
local xray = true
local xrayBtn, recenterBtn
local solveCells, bayName = nil, "?"
local bayLevel = nil          -- cubes per cell, for the order card
local occupied = {}
local markers = {}
local hidden = {}          -- part -> its real LocalTransparencyModifier
local highlight = nil

local overlay = Instance.new("Folder")
overlay.Name = "OverseerOverlay"
overlay.Parent = Workspace

----------------------------------------------------------------
-- Panel
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "OverseerCam"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 12
gui.Parent = playerGui

----------------------------------------------------------------
-- THE ORDER CARD. The most important thing on player 2's screen.
----------------------------------------------------------------
-- Player 2's entire job is "put a cube on the mat at the right square". Everything they need
-- for that is one coordinate and one quantity, and it used to be spelled out nowhere -- the
-- old panel said "2 cells want a block" and left them to find which two on a 4x3 of
-- identically-styled squares. This card answers it directly, in the largest type on screen,
-- and the mat below is now the confirmation rather than the instruction.
local card = Ui.panel({
	parent = gui,
	name = "OrderCard",
	title = "NEXT BLOCK",
	size = UDim2.fromOffset(250, 150),
	position = UDim2.new(1, -18, 0, 92),
	anchor = Vector2.new(1, 0),
	tone = "ok",
	zindex = 3,
})

local crateHolder = Instance.new("Frame")
crateHolder.BackgroundTransparency = 1
crateHolder.Size = UDim2.fromOffset(52, 62)
crateHolder.Position = UDim2.fromOffset(0, 2)
crateHolder.ZIndex = card.body.ZIndex + 1
crateHolder.Parent = card.body

local function drawCrate(count)
	crateHolder:ClearAllChildren()
	if count and count > 0 then
		Ui.crateIcon(crateHolder, {count = count, anchor = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 0, 1, 0), size = UDim2.fromOffset(40, 58)})
	end
end
drawCrate(1)

-- The coordinate, as big as it will go. Two lines, because "COL 1 ROW 0" on one line reads as
-- a single four-token string the operator has to parse; stacked, it is two facts.
local colLabel = Ui.text(card.body, {style = "task", text = "--", textSize = 30,
	align = Enum.TextXAlignment.Left, position = UDim2.fromOffset(62, 2),
	size = UDim2.new(1, -62, 0, 32)})
local rowLabel = Ui.text(card.body, {style = "task", text = "", textSize = 30,
	align = Enum.TextXAlignment.Left, position = UDim2.fromOffset(62, 32),
	size = UDim2.new(1, -62, 0, 32)})

local qtyLabel = Ui.text(card.body, {style = "caption", text = "",
	align = Enum.TextXAlignment.Center, position = UDim2.fromOffset(0, 70),
	size = UDim2.new(1, 0, 0, 14)})
Ui.rule(card.body, 88, 4)
local progressLabel = Ui.text(card.body, {style = "hint", text = "", textSize = 13,
	position = UDim2.fromOffset(0, 93), size = UDim2.new(1, 0, 0, 16)})

----------------------------------------------------------------
-- The mat
----------------------------------------------------------------
local matPanel = Ui.panel({
	parent = gui,
	name = "Mat",
	title = "THE MAT   -   far end at the top",
	size = UDim2.fromOffset(250, 236),
	position = UDim2.new(1, -18, 0, 252),
	anchor = Vector2.new(1, 0),
	tone = "info",
	zindex = 3,
})
local gridFrame = matPanel.body

local cellBtns = {}
for col = 0, Config.BayCols - 1 do
	for row = 0, Config.BayRows - 1 do
		local f = Instance.new("Frame")
		-- row 2 (far) at the top, col 0 on the right: the same way round as the real mat
		f.Position = UDim2.fromOffset((Config.BayCols - 1 - col) * 54,
			(Config.BayRows - 1 - row) * 54)
		f.Size = UDim2.fromOffset(50, 50)
		f.BackgroundColor3 = Ui.C.ironDark
		f.BorderSizePixel = 0
		f.ZIndex = gridFrame.ZIndex + 1
		f.Parent = gridFrame
		Ui.corner(f, 4)
		local st = Ui.stroke(f, Ui.C.brassDim, 1.5)
		local t = Ui.text(f, {style = "label", text = ("%d,%d"):format(col, row), textSize = 12,
			align = Enum.TextXAlignment.Center, colour = Ui.C.ghost,
			size = UDim2.fromScale(1, 1), zindex = gridFrame.ZIndex + 2})
		cellBtns[col .. "," .. row] = {frame = f, stroke = st, label = t}
	end
end

Ui.text(gridFrame, {style = "caption", text = "amber = place here      green = placed      blue = runner",
	align = Enum.TextXAlignment.Center, position = UDim2.fromOffset(0, 168),
	size = UDim2.new(1, 0, 0, 14)})

----------------------------------------------------------------
-- Banner and controls
----------------------------------------------------------------
local bannerPanel = Ui.panel({
	parent = gui,
	name = "Banner",
	size = UDim2.fromOffset(540, 58),
	position = UDim2.new(0.5, 0, 1, -18),
	anchor = Vector2.new(0.5, 1),
	tone = "info",
	zindex = 3,
})
local banner = Ui.text(bannerPanel.body, {style = "title", text = "OVERSEER VIEW",
	textSize = 17, colour = Ui.C.amber, size = UDim2.new(1, 0, 0, 20)})
local sub = Ui.text(bannerPanel.body, {style = "hint", text = "", textSize = 11,
	position = UDim2.fromOffset(0, 20), size = UDim2.new(1, 0, 0, 14)})

local function ctrlButton(text, y)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -18, 0, y)
	b.Size = UDim2.fromOffset(250, 30)
	b.BackgroundColor3 = Ui.C.ironLight
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Ui.F.label
	b.TextSize = 11
	b.TextColor3 = Ui.C.faded
	b.Text = text
	b.ZIndex = 3
	b.Parent = gui
	Ui.corner(b, 4)
	Ui.stroke(b, Ui.C.brassDim, 1.5)
	Ui.sheen(b, 0.2)
	return b
end

xrayBtn = ctrlButton("WALLS: SEE-THROUGH  (G)", 18)
recenterBtn = ctrlButton("RECENTER VIEW", 52)

----------------------------------------------------------------
-- Keeping the card truthful
----------------------------------------------------------------
-- The "next" cell is the first wanted one not already filled, in the server's own solveCells
-- order -- so for a routed bay like the laser walk this follows the route rather than
-- inventing an order of its own.
local function nextWantedCell()
	for _, c in ipairs(solveCells or {}) do
		if not occupied[c[1] .. "," .. c[2]] then
			return c[1], c[2]
		end
	end
	return nil
end

local function refreshCard()
	local total = #(solveCells or {})
	local filled = 0
	for _, c in ipairs(solveCells or {}) do
		if occupied[c[1] .. "," .. c[2]] then
			filled += 1
		end
	end

	local col, row = nextWantedCell()
	if col then
		card.setTone("ok")
		card.setTitle("NEXT BLOCK")
		colLabel.Text = "COL " .. col
		rowLabel.Text = "ROW " .. row
		colLabel.TextColor3 = Ui.C.amber
		rowLabel.TextColor3 = Ui.C.amber
		qtyLabel.Text = (bayLevel and bayLevel > 1)
			and ("STACK " .. bayLevel .. " CUBES") or "ONE CUBE"
		drawCrate(bayLevel or 1)
	elseif total > 0 then
		card.setTone("ok")
		card.setTitle("ALL PLACED")
		colLabel.Text = "STAND"
		rowLabel.Text = "BY"
		colLabel.TextColor3 = Ui.C.ok
		rowLabel.TextColor3 = Ui.C.ok
		qtyLabel.Text = "NOTHING TO PLACE"
		drawCrate(nil)
	else
		-- an action bay: its cells are decided at runtime, or there are none at all
		card.setTone("warn")
		card.setTitle("NO CELL CALLED")
		colLabel.Text = "WAIT"
		rowLabel.Text = ""
		colLabel.TextColor3 = Ui.C.faded
		rowLabel.TextColor3 = Ui.C.faded
		qtyLabel.Text = "THIS BAY CLEARS BY ACTION"
		drawCrate(nil)
	end

	progressLabel.Text = (total > 0)
		and ("%d of %d cells filled"):format(filled, total)
		or "watch the runner"
end

----------------------------------------------------------------
-- In-world cell markers
----------------------------------------------------------------
local function clearMarkers()
	for _, m in ipairs(markers) do
		if m then
			m:Destroy()
		end
	end
	table.clear(markers)
end

local function wantedSet()
	local want = {}
	for _, c in ipairs(solveCells or {}) do
		want[c[1] .. "," .. c[2]] = true
	end
	return want
end

local function buildMarkers()
	clearMarkers()
	local bay = Workspace.Warehouse:FindFirstChild(("Bay%02d"):format(activeBay))
	local anchors = bay and bay:FindFirstChild("CrateAnchors")
	if not anchors then
		return
	end
	local want = wantedSet()
	for col = 0, Config.BayCols - 1 do
		for row = 0, Config.BayRows - 1 do
			local a = anchors:FindFirstChild(("Cell_%d_%d"):format(col, row))
			if a then
				local key = col .. "," .. row
				local isWanted = want[key]
				local pad = Instance.new("Part")
				pad.Name = "OverseerCell_" .. key
				pad.Anchored = true
				pad.CanCollide = false
				pad.CanQuery = false
				pad.CanTouch = false
				pad.Size = Vector3.new(CELL - 1.2, 0.08, CELL - 1.2)
				pad.CFrame = CFrame.new(a.Position + Vector3.new(0, 0.1, 0))
				pad.Material = Enum.Material.Neon
				pad.Transparency = isWanted and 0.35 or 0.86
				pad.Color = isWanted and WANT or Color3.fromRGB(90, 130, 190)
				pad.Parent = overlay
				table.insert(markers, pad)

				local sg = Instance.new("SurfaceGui")
				sg.Face = Enum.NormalId.Top
				sg.LightInfluence = 0
				sg.PixelsPerStud = 36
				sg.Adornee = pad
				sg.Parent = pad
				local t = Instance.new("TextLabel")
				t.AnchorPoint = Vector2.new(0.5, 0.5)
				t.Position = UDim2.new(0.5, 0, 0.5, 0)
				t.Size = UDim2.new(0.62, 0, 0.42, 0)
				t.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
				t.BackgroundTransparency = isWanted and 0.1 or 0.32
				t.BorderSizePixel = 0
				t.Font = Enum.Font.GothamBold
				t.Rotation = -90
				t.TextScaled = true
				t.TextColor3 = isWanted and Color3.fromRGB(130, 255, 170) or INK
				t.Text = ("%d,%d"):format(col, row)
				t.Parent = sg
				Instance.new("UICorner", t).CornerRadius = UDim.new(0.18, 0)
				local ts = Instance.new("UIStroke", t)
				ts.Color = isWanted and Color3.fromRGB(70, 200, 120)
					or Color3.fromRGB(80, 92, 112)
				ts.Thickness = 2
			end
		end
	end
end

----------------------------------------------------------------
-- X-ray: the shell, plus the active bay's own walls and ceiling.
----------------------------------------------------------------
local function ghost(part, amount)
	if part:IsA("BasePart") and hidden[part] == nil then
		hidden[part] = part.LocalTransparencyModifier
		part.LocalTransparencyModifier = amount
	end
end

local function ghostWalls(on)
	if not on then
		for p, v in pairs(hidden) do
			if p and p.Parent then
				p.LocalTransparencyModifier = v
			end
		end
		table.clear(hidden)
		return
	end

	local shell = Workspace.Warehouse:FindFirstChild("Shell")
	for _, p in ipairs(shell and shell:GetChildren() or {}) do
		ghost(p, 0.92)
	end

	-- The roof trusses sit at y = 46, between a 62-stud camera and the floor, and laid two
	-- black bars straight across the bay. The rail beams are left alone: they are thin, they
	-- are where the crane actually rides, and seeing the crane is useful.
	local rails = Workspace.Warehouse:FindFirstChild("SkyRails")
	for _, p in ipairs(rails and rails:GetChildren() or {}) do
		if p.Name:match("^Truss") then
			ghost(p, 1)
		end
	end

	-- The crane hangs directly over the bay and is the single biggest thing between this
	-- camera and the floor. Faded rather than hidden: where the jaw is still tells the
	-- operator what the arm is doing.
	local rig = Workspace:FindFirstChild("SkyArmRig")
	for _, p in ipairs(rig and rig:GetDescendants() or {}) do
		ghost(p, 0.75)
	end

	-- Backdrop scenery over the course -- the hall's roof deck, skylight and arch ribs --
	-- carries the "OverseerHide" tag instead of being enumerated here: the generators in
	-- build/ own the tag, this script just honours it. Hidden outright (not faded) because
	-- at zoom-out the camera rises to ~143 and all of it sits between camera and floor.
	for _, p in ipairs(CollectionService:GetTagged("OverseerHide")) do
		ghost(p, 1)
	end

	-- The bay's own box. Matched by NAME rather than by size or position, because a bay builds
	-- whatever it needs and only its walls and roof should disappear -- the obstacle itself has
	-- to stay visible, which is the entire point of looking.
	local bay = Workspace.Warehouse:FindFirstChild(("Bay%02d"):format(activeBay))
	local obst = bay and bay:FindFirstChild("Obstacle")
	for _, p in ipairs(obst and obst:GetChildren() or {}) do
		local n = p.Name
		if n:match("Ceiling") then
			ghost(p, 1)            -- a roof between camera and floor has to go entirely
		elseif n:match("Wall") or n:match("SideRail") then
			ghost(p, 0.82)         -- walls stay faintly, so the room keeps its shape
		end
	end
end

----------------------------------------------------------------
-- The runner. Outlined, so they are findable in a dark room or behind an obstacle.
----------------------------------------------------------------
local function setHighlight(on)
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if not on then
		return
	end
	local ch = player.Character
	if not ch then
		return
	end
	highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(120, 210, 255)
	highlight.FillTransparency = 0.5
	highlight.OutlineColor = Color3.fromRGB(200, 240, 255)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Adornee = ch
	highlight.Parent = ch
end

local function runnerCell()
	local ch = player.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local zStart = (activeBay - 1) * Config.BayPitch
	local col = math.floor(hrp.Position.X / CELL)
	local row = math.floor((hrp.Position.Z - zStart) / CELL)
	if col < 0 or col >= Config.BayCols or row < 0 or row >= Config.BayRows then
		return nil
	end
	return col .. "," .. row
end

----------------------------------------------------------------
-- The view
----------------------------------------------------------------
local function aimCamera()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local zStart = (activeBay - 1) * Config.BayPitch
	local midX = Config.BayWidth / 2
	local midZ = zStart + Config.BayDepth / 2
	-- Aimed past the middle of the bay, which pushes the whole grid DOWN the screen and out
	-- from under the objective panel. Aiming at the centre put the far row behind it.
	local h = HEIGHT * zoom
	local back = SETBACK * zoom
	-- Clamped, because an unbounded pan is a way to lose the bay entirely and no way to find
	-- it again: a few flicks and the operator is staring at empty sky with no horizon to
	-- steer by. The limit scales with zoom -- zoomed out you can afford to roam further.
	local lim = PAN_LIMIT * zoom
	panX = math.clamp(panX, -lim, lim)
	panZ = math.clamp(panZ, -lim, lim)
	cam.CFrame = CFrame.lookAt(
		Vector3.new(midX + panX, h, midZ - back + panZ),
		Vector3.new(midX + panX, 0, midZ + 10 + panZ))
end

local nextKey = nil        -- the one cell the operator should be reaching for

local function paintGrid()
	local want = wantedSet()
	local here = runnerCell()
	local nc, nr = nextWantedCell()
	nextKey = nc and (nc .. "," .. nr) or nil

	for key, c in pairs(cellBtns) do
		local isNext = (key == nextKey)
		local isWanted = want[key]
		local isHeld = occupied[key]
		local isHere = (key == here)

		-- Priority is deliberate and is the whole point of the redesign: THE NEXT CELL WINS.
		-- Everything else on this grid is context. Before, every wanted cell was painted the
		-- same green and the operator had to work out which of them to do first.
		if isNext then
			c.frame.BackgroundColor3 = Color3.fromRGB(58, 42, 18)
			c.stroke.Color = WANT
			c.stroke.Thickness = 3
			c.label.TextColor3 = WANT
		elseif isHeld then
			c.frame.BackgroundColor3 = Color3.fromRGB(22, 46, 32)
			c.stroke.Color = HELD
			c.stroke.Thickness = 2
			c.label.TextColor3 = HELD
		elseif isWanted then
			c.frame.BackgroundColor3 = Color3.fromRGB(40, 32, 20)
			c.stroke.Color = Ui.C.brassDim
			c.stroke.Thickness = 1.5
			c.label.TextColor3 = Ui.C.faded
		else
			c.frame.BackgroundColor3 = Ui.C.ironDark
			c.stroke.Color = Ui.C.brassDim
			c.stroke.Thickness = 1
			c.label.TextColor3 = DIMMED
		end

		-- the runner's square is marked on top of whatever it already is
		if isHere then
			c.stroke.Color = RUNNER
			c.stroke.Thickness = 3
		end
	end

	refreshCard()
end

local function setActive(on)
	active = on
	gui.Enabled = on
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if on then
		cam.CameraType = Enum.CameraType.Scriptable
		ghostWalls(xray)
		setHighlight(true)
		buildMarkers()
		aimCamera()
		paintGrid()
	else
		clearMarkers()
		panning = false
		ghostWalls(false)
		setHighlight(false)
		cam.CameraType = Enum.CameraType.Custom
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
	end
end

local function refreshBanner()
	banner.Text = ("OVERSEER VIEW   -   BAY %02d   -   %s"):format(activeBay, bayName:upper())
	sub.Text = ("scroll or -/= zoom   .   right-drag pan   .   G walls %s   .   V back to the runner")
		:format(xray and "see-through" or "solid")
end

-- X-RAY, one place. It is reached three ways -- the G key, the on-screen button, and a bay
-- change re-applying it -- and having each of those poke the flag by hand is how the banner
-- and the world drifted apart.
--
-- G IS CLAIMED THROUGH ContextActionService, not UserInputService.InputBegan. V arrives on
-- InputBegan and G did not: something upstream was marking it handled, and InputBegan's
-- gameProcessedEvent guard then dropped it before this script ever saw it. A bound action
-- sits above that and sinks the key, so the binding holds regardless of who else wants it.
local function setXray(on)
	xray = on
	ghostWalls(false)
	ghostWalls(xray)
	refreshBanner()
	if xrayBtn then
		xrayBtn.Text = xray and "WALLS: SEE-THROUGH  (G)" or "WALLS: SOLID  (G)"
		xrayBtn.BackgroundColor3 = xray and Color3.fromRGB(26, 52, 86) or Color3.fromRGB(34, 38, 48)
		xrayBtn.TextColor3 = xray and HELD or DIMMED
	end
end

-- ZOOM IS BOUND THE SAME WAY, AND FOR THE SAME REASON. Roblox's own camera module claims the
-- mouse wheel through ContextActionService, so by the time a wheel turn reaches
-- InputChanged it is already flagged handled and a gameProcessedEvent guard eats it --
-- CameraType = Scriptable stops the module MOVING the camera, it does not stop it listening.
-- Binding above it is the only way to get the wheel.
--
-- The - and = keys do the same job. A wheel is not a given -- half of demoing this happens on
-- a laptop trackpad -- and a contested input with no alternative is one that just fails.
local function stepZoom(by)
	zoom = math.clamp(zoom + by, ZOOM_MIN, ZOOM_MAX)
	aimCamera()
end

ContextActionService:BindActionAtPriority("OverseerZoom", function(_, state, input)
	if not active then
		return Enum.ContextActionResult.Pass
	end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if state == Enum.UserInputState.Change and input.Position.Z ~= 0 then
			stepZoom(-input.Position.Z * 0.12)
		end
	elseif state == Enum.UserInputState.Begin then
		stepZoom(input.KeyCode == Enum.KeyCode.Minus and 0.18 or -0.18)
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value,
	Enum.UserInputType.MouseWheel, Enum.KeyCode.Minus, Enum.KeyCode.Equals)

ContextActionService:BindActionAtPriority("OverseerXray", function(_, state)
	if not active then
		-- the runner is driving; G is none of this script's business
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		setXray(not xray)
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.G)

xrayBtn.MouseButton1Click:Connect(function()
	setXray(not xray)
end)

recenterBtn.MouseButton1Click:Connect(function()
	zoom, panX, panZ = 1, 0, 0
	aimCamera()
end)

local resetToken = nil

DebugStatus.OnClientEvent:Connect(function(status)
	-- A full reset puts the course back to bay 1, which usually reads as a bay change -- but
	-- not when you full-reset while already on bay 1, and then the camera kept whatever zoom
	-- and pan the last run left it with. The token changes either way.
	local wasReset = resetToken ~= nil and status.resetToken ~= resetToken
	resetToken = status.resetToken

	local moved = status.activeBay ~= activeBay or wasReset
	activeBay = status.activeBay or activeBay
	local info = status.bays and status.bays[activeBay]
	solveCells = info and info.solveCells or nil
	bayName = info and info.obstacle or "?"
	bayLevel = info and info.level or nil
	if moved then
		occupied = {}
		zoom, panX, panZ = 1, 0, 0    -- a new bay gets the default framing back
	end
	refreshBanner()
	if active then
		-- the bay moved under us, or a solve changed which cells matter, and the x-ray has to
		-- follow: the walls being ghosted belong to the bay we were looking at
		ghostWalls(false)
		ghostWalls(xray)
		buildMarkers()
		paintGrid()
		if moved then
			aimCamera()
		end
	end
end)

BayCells.OnClientEvent:Connect(function(bayIndex, cellsList)
	if bayIndex ~= activeBay then
		return
	end
	local now = {}
	for _, c in ipairs(cellsList or {}) do
		now[c.col .. "," .. c.row] = true
	end
	occupied = now
	if active then
		paintGrid()
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode == Enum.KeyCode.V and not processed then
		setActive(not active)
		return
	end
	-- Right button starts a pan. The processed guard is skipped on purpose: the operator
	-- grabs the view by dragging over the middle of the screen, and the objective panel and
	-- the mini grid both sit in that space.
	if active and input.UserInputType == Enum.UserInputType.MouseButton2 then
		panning = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		panning = false
	end
end)

-- Right-drag to pan. No processed guard: the drag starts over the middle of the screen,
-- where the objective panel and the mini grid both live. (Zoom is a bound action, above.)
UserInputService.InputChanged:Connect(function(input)
	if not active then
		return
	end
	if panning and input.UserInputType == Enum.UserInputType.MouseMovement then
		-- The camera looks down -Z-ish, so screen-right is world +X and screen-up is world
		-- +Z. Scaled by zoom so a drag covers the same amount of SCREEN at any zoom.
		panX -= input.Delta.X * PAN_PER_PIXEL * zoom
		panZ += input.Delta.Y * PAN_PER_PIXEL * zoom
		aimCamera()
	end
end)

-- The camera and the highlight are both lost on respawn; re-assert rather than leaving the
-- overseer staring through their own character.
player.CharacterAdded:Connect(function()
	task.wait(0.4)
	if active then
		setActive(true)
	end
end)

-- The camera is re-asserted every frame rather than only when it moves: Roblox hands the
-- camera back to the default scripts on respawn and on a few CoreGui transitions, and a
-- one-shot CFrame would silently lose the view.
RunService.RenderStepped:Connect(function()
	if not active then
		return
	end
	aimCamera()
	-- A slow breath on the one cell being asked for. Motion is what the eye finds first in a
	-- grid of twelve identical squares, and it costs one property write a frame.
	local c = nextKey and cellBtns[nextKey]
	if c then
		c.stroke.Transparency = 0.35 + 0.35 * math.sin(os.clock() * 4)
	end
end)

-- The runner's cell changes as they move, which no event reports.
task.spawn(function()
	while true do
		if active then
			paintGrid()
		end
		task.wait(0.25)
	end
end)

DebugCommand:FireServer("status")
print("[OverseerCam] V toggles the overseer view")
