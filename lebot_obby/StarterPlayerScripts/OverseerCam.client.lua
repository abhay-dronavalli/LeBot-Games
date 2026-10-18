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

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DebugStatus = Remotes:WaitForChild("DebugStatus")
local DebugCommand = Remotes:WaitForChild("DebugCommand")
local BayCells = Remotes:WaitForChild("BayCells")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CELL = Config.CellSize
local HEIGHT = 62          -- steep: the grid has to read as a grid
local SETBACK = 9          -- a few degrees of tilt so the room keeps its walls

local INK = Color3.fromRGB(232, 236, 244)
local WANT = Color3.fromRGB(90, 230, 130)
local HELD = Color3.fromRGB(96, 170, 255)
local DIMMED = Color3.fromRGB(96, 104, 122)

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
gui.Parent = playerGui

local banner = Instance.new("TextLabel")
-- Bottom of the screen. The objective panel owns the top centre -- it is the runner's task
-- readout and the overseer needs it too -- so these were drawing straight over each other.
banner.AnchorPoint = Vector2.new(0.5, 1)
banner.Position = UDim2.new(0.5, 0, 1, -34)
banner.Size = UDim2.new(0, 460, 0, 30)
banner.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
banner.BackgroundTransparency = 0.12
banner.BorderSizePixel = 0
banner.Font = Enum.Font.GothamBold
banner.TextSize = 15
banner.TextColor3 = Color3.fromRGB(120, 200, 255)
banner.Text = "OVERSEER VIEW"
banner.Parent = gui
Instance.new("UICorner", banner).CornerRadius = UDim.new(0, 6)

local sub = Instance.new("TextLabel")
sub.AnchorPoint = Vector2.new(0.5, 1)
sub.Position = UDim2.new(0.5, 0, 1, -12)
sub.Size = UDim2.new(0, 460, 0, 18)
sub.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
sub.BackgroundTransparency = 0.25
sub.BorderSizePixel = 0
sub.Font = Enum.Font.Gotham
sub.TextSize = 12
sub.TextColor3 = Color3.fromRGB(176, 186, 202)
sub.Text = "V returns to the runner"
sub.Parent = gui
Instance.new("UICorner", sub).CornerRadius = UDim.new(0, 5)

----------------------------------------------------------------
-- Controls the operator can hit without knowing a keybind. The keys stay, but a hackathon
-- demo gets driven by someone who has never seen this screen before, and a visible button is
-- the difference between "the walls are in my way" and "I pressed the walls button".
----------------------------------------------------------------
local function ctrlButton(text, y)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -18, 0, y)
	b.Size = UDim2.new(0, 214, 0, 28)
	b.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
	b.BackgroundTransparency = 0.08
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.TextColor3 = DIMMED
	b.Text = text
	b.Parent = gui
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	return b
end

xrayBtn = ctrlButton("WALLS: SEE-THROUGH  (G)", 18)
recenterBtn = ctrlButton("RECENTER VIEW", 52)

----------------------------------------------------------------
-- Mini grid. The same 4x3 the operator has in front of them on the table, in the same
-- orientation, so what is on screen and what they reach for line up without translating.
----------------------------------------------------------------
local gridFrame = Instance.new("Frame")
gridFrame.AnchorPoint = Vector2.new(1, 0.5)
gridFrame.Position = UDim2.new(1, -18, 0.5, 0)
gridFrame.Size = UDim2.new(0, 214, 0, 190)
gridFrame.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
gridFrame.BackgroundTransparency = 0.12
gridFrame.BorderSizePixel = 0
gridFrame.Parent = gui
Instance.new("UICorner", gridFrame).CornerRadius = UDim.new(0, 8)

local gridTitle = Instance.new("TextLabel")
gridTitle.Position = UDim2.new(0, 10, 0, 7)
gridTitle.Size = UDim2.new(1, -20, 0, 16)
gridTitle.BackgroundTransparency = 1
gridTitle.Font = Enum.Font.GothamBold
gridTitle.TextSize = 11
gridTitle.TextXAlignment = Enum.TextXAlignment.Left
gridTitle.TextColor3 = Color3.fromRGB(150, 158, 172)
gridTitle.Text = "THE MAT   -   far end at the top"
gridTitle.Parent = gridFrame

local cellBtns = {}
for col = 0, Config.BayCols - 1 do
	for row = 0, Config.BayRows - 1 do
		local f = Instance.new("Frame")
		-- row 2 (far) at the top, col 0 on the right: the same way round as the debug grid
		f.Position = UDim2.new(0, 10 + (Config.BayCols - 1 - col) * 49,
			0, 28 + (Config.BayRows - 1 - row) * 49)
		f.Size = UDim2.new(0, 45, 0, 45)
		f.BackgroundColor3 = Color3.fromRGB(30, 34, 44)
		f.BorderSizePixel = 0
		f.Parent = gridFrame
		Instance.new("UICorner", f).CornerRadius = UDim.new(0, 5)
		local st = Instance.new("UIStroke", f)
		st.Color = Color3.fromRGB(52, 58, 72)
		st.Thickness = 1
		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, 0, 1, 0)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.TextSize = 12
		t.TextColor3 = DIMMED
		t.Text = ("%d,%d"):format(col, row)
		t.Parent = f
		cellBtns[col .. "," .. row] = {frame = f, stroke = st, label = t}
	end
end

local legend = Instance.new("TextLabel")
legend.Position = UDim2.new(0, 10, 1, -18)
legend.Size = UDim2.new(1, -20, 0, 14)
legend.BackgroundTransparency = 1
legend.Font = Enum.Font.Gotham
legend.TextSize = 10
legend.TextXAlignment = Enum.TextXAlignment.Left
legend.TextColor3 = Color3.fromRGB(130, 138, 152)
legend.Text = "green wanted   blue placed   amber runner"
legend.Parent = gridFrame

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

local function paintGrid()
	local want = wantedSet()
	local here = runnerCell()
	for key, c in pairs(cellBtns) do
		local isWanted = want[key]
		local isHeld = occupied[key]
		local isHere = (key == here)
		c.frame.BackgroundColor3 = isHeld and Color3.fromRGB(26, 52, 86)
			or (isWanted and Color3.fromRGB(22, 54, 36) or Color3.fromRGB(30, 34, 44))
		c.stroke.Color = isHere and Color3.fromRGB(255, 210, 110)
			or (isHeld and HELD or (isWanted and WANT or Color3.fromRGB(52, 58, 72)))
		c.stroke.Thickness = isHere and 3 or (isHeld and 2 or 1)
		c.label.TextColor3 = isHeld and HELD or (isWanted and WANT or DIMMED)
	end
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
	local n = #(solveCells or {})
	sub.Text = ("%s   -   scroll or -/= zoom, right-drag pan, G walls %s, V back to the runner"):format(
		(n > 0) and ("%d cells want a block"):format(n) or "cleared by an action, not by cells",
		xray and "see-through" or "solid")
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
	if active then
		aimCamera()
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
