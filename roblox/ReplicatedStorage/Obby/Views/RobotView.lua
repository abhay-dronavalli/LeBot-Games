-- ReplicatedStorage.Obby.Views.RobotView (ModuleScript)
-- Robo Obby's robot view (Core.Games.Obby): what the operator at the real arm sees while the Obby is the
-- active game. The arcade port of lebot_obby/StarterPlayerScripts/OverseerCam.client.lua (Kushagra's
-- overseer view, his notes kept below), turned into enter(ctx) / exit():
--   * enter builds the panel and the overlay and turns the overseer view ON at once. The robot role has no
--     runner of its own to flip back to, so there is no V key. Zoom (wheel, - / =), right-drag pan, G walls
--     and the two buttons stay: they are the operator's controls.
--   * the robot has NO character. The "runner" it outlines and tracks on the mini grid is the player whose
--     Role attribute is "player" (fallback: any other player with a character).
--   * the world is workspace.ObbyMap (cloned in each round, ModelStreamingMode Persistent). It is waited for
--     by the paint loop, not by enter, so enter never holds up Core RoleClient; the bays sit Config.OriginZ
--     down +Z, so every Z worked out from a bay index adds it (bayZStart).
--   * Remotes.Status (activeBay, solveCells, resetToken, feedMode, linkOnline) and Remotes.BayCells (the
--     occupied cells) drive the grid; Remotes.Objective (the runner's task, copied to the robot by the
--     server) shows top centre with the runner's ObjectiveHud look. A status pill top left: the run clock
--     (ReplicatedStorage.Obby RunEndsAt / RunState), the feed mode, and ROBOT LINK OFFLINE when the feed is
--     live and the core link is down.
--   * exit disconnects everything, stops the paint loop, puts back every LocalTransparencyModifier it
--     ghosted, destroys the overlay, the highlight and the GUI, unbinds its actions and puts the camera back
--     (FloodRobotView's savedCamera). Never touches Lighting.
--
-- OverseerCam -- player 2's view of the bay.
--
-- The overseer's job is to put real cubes on a real mat and have them land in the right cells.
-- That needs a view where the 4x3 grid is legible, the runner is findable, and the obstacle is
-- visible at the same time. The runner's over-the-shoulder camera is none of those.
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

local Obby = ReplicatedStorage:WaitForChild("Obby")
local Config = require(Obby:WaitForChild("Config"))

local Remotes = Obby:WaitForChild("Remotes")
local Status = Remotes:WaitForChild("Status")
local BayCells = Remotes:WaitForChild("BayCells")
local Objective = Remotes:WaitForChild("Objective")

local player = Players.LocalPlayer

local MAP_NAME = "ObbyMap"
local CELL = Config.CellSize
local HEIGHT = 62          -- steep: the grid has to read as a grid
local SETBACK = 9          -- a few degrees of tilt so the room keeps its walls
-- HEIGHT and SETBACK were tuned on the default camera's field of view. The robot camera is fully
-- scripted and may arrive from another view with a different one, so the view sets it (and exit puts
-- the old one back).
local FOV = 70

local INK = Color3.fromRGB(232, 236, 244)
local WANT = Color3.fromRGB(90, 230, 130)
local HELD = Color3.fromRGB(96, 170, 255)
local DIMMED = Color3.fromRGB(96, 104, 122)

local TONE = {
	danger = Color3.fromRGB(255, 92, 80),
	warn = Color3.fromRGB(255, 190, 70),
	ok = Color3.fromRGB(120, 240, 150),
}
local DIM = Color3.fromRGB(165, 165, 180)

local RobotView = {}

local active = false
local activeBay = Config.LiveBay or 1
local generation = 0       -- bumped by exit: the paint loop of an older enter stops on it
local connections = {}
local savedCamera = nil
local map, warehouse = nil, nil

local function track(conn)
	table.insert(connections, conn)
	return conn
end

-- Course Z of bay i's entrance edge, in world space (RunControl.bayZStart): the map is baked
-- Config.OriginZ down +Z, so the old "bay 1 starts at Z = 0" needs the offset added back.
local function bayZStart(i)
	return Config.OriginZ + (i - 1) * Config.BayPitch
end

-- Camera the overseer can actually drive. A fixed shot is fine until you need to look at one
-- corner of the bay, which is most of the time once a run is underway.
--
-- PAN IS ON THE RIGHT MOUSE BUTTON, not on keys. Every key that reads as "move the view" --
-- WASD and the arrows alike -- is already a key that WALKS THE RUNNER, and in solo the
-- overseer and the runner are the same person. Panning with the arrows marched the character
-- out of the bay while the operator thought they were looking around.
-- (In the arcade the robot role has no character to walk, but the binding stays as he built it.)
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
local status = nil         -- the last Remotes.Status payload

local overlay
local gui, banner, sub, gridFrame
local cellBtns = {}
local objectiveUi, statusUi

----------------------------------------------------------------
-- Panel
----------------------------------------------------------------
-- Controls the operator can hit without knowing a keybind. The keys stay, but a hackathon
-- demo gets driven by someone who has never seen this screen before, and a visible button is
-- the difference between "the walls are in my way" and "I pressed the walls button".
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

-- The runner's task panel, ported from Views.Player.ObjectiveHud (same look, same place: top
-- centre). The camera already aims past the bay's middle to keep the grid out from under it,
-- which is the layout this view was built around when the runner's HUD shared the screen.
-- Payload: {title, task, hint, tone, timer, timerLabel, timerTone, flash, steps, note}
local function buildObjective(parent)
	local root = Instance.new("Frame")
	root.Name = "Objective"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, 14)
	root.Size = UDim2.new(0, 470, 0, 112)
	root.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
	root.BackgroundTransparency = 0.22
	root.BorderSizePixel = 0
	root.Visible = false
	root.Parent = parent

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

	local ui = {
		root = root,
		stripe = stripe,
		title = line(10, 16, 14, DIM, true),
		task = line(28, 28, 24, TONE.danger, true),
		hint = line(57, 18, 15, DIM, false),
		timerLabel = line(78, 16, 13, DIM, true),
		timerValue = line(90, 22, 20, Color3.fromRGB(255, 255, 255), true),
		steps = {},
	}
	for idx = 1, 4 do
		local l = line(112 + (idx - 1) * 19, 17, 15, DIM, false)
		l.TextXAlignment = Enum.TextXAlignment.Left
		l.Position = UDim2.new(0, 22, 0, 112 + (idx - 1) * 19)
		l.Size = UDim2.new(1, -44, 0, 17)
		l.Visible = false
		ui.steps[idx] = l
	end
	ui.note = line(112, 30, 13, DIM, false)
	ui.note.TextWrapped = true
	ui.note.Visible = false

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
	flash.Parent = parent
	corner:Clone().Parent = flash
	ui.flash = flash
	return ui
end

local function showObjective(ui, p)
	if not p then
		ui.root.Visible = false
		ui.flash.Visible = false
		return
	end

	ui.root.Visible = true
	local tone = TONE[p.tone] or TONE.danger
	ui.stripe.BackgroundColor3 = tone
	ui.task.TextColor3 = tone

	ui.title.Text = p.title or ""
	ui.task.Text = p.task or ""
	ui.hint.Text = p.hint or ""

	if p.timer then
		ui.timerLabel.Text = p.timerLabel or ""
		-- whole seconds only; a ticking fraction reads as noise at this size
		local secs = math.max(0, math.floor(p.timer + 0.5))
		ui.timerValue.Text = string.format("%d:%02d", math.floor(secs / 60), secs % 60)
		ui.timerValue.TextColor3 = (p.timerTone and TONE[p.timerTone])
			or (secs <= 10 and TONE.danger)
			or Color3.fromRGB(255, 255, 255)
		ui.timerLabel.Visible = true
		ui.timerValue.Visible = true
	else
		ui.timerLabel.Visible = false
		ui.timerValue.Visible = false
	end

	local used = 0
	for idx, l in ipairs(ui.steps) do
		local text = p.steps and p.steps[idx]
		l.Visible = text ~= nil
		if text then
			used = idx
			l.Text = text
			l.TextColor3 = text:find("%[x%]") and TONE.ok
				or text:find("%[%-%]") and Color3.fromRGB(120, 124, 136)
				or Color3.fromRGB(226, 230, 240)
		end
	end

	local noteTop = 112 + used * 19 + 2
	ui.note.Visible = p.note ~= nil
	if p.note then
		ui.note.Text = p.note
		ui.note.Position = UDim2.new(0, 22, 0, noteTop)
		ui.note.Size = UDim2.new(1, -44, 0, 30)
	end

	local panelHeight = 112 + used * 19 + (p.note and 34 or 0) + 8
	ui.root.Size = UDim2.new(0, 470, 0, math.max(120, panelHeight))
	ui.flash.Position = UDim2.new(0.5, 0, 0, math.max(132, panelHeight + 10))

	ui.flash.Text = p.flash or ""
	ui.flash.Visible = (p.flash ~= nil)
end

-- Top left: the run clock and who owns the crates this round.
local function buildStatus(parent)
	local frame = Instance.new("Frame")
	frame.Name = "RunStatus"
	frame.Position = UDim2.new(0, 18, 0, 18)
	frame.Size = UDim2.new(0, 214, 0, 52)
	frame.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Parent = parent
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

	local clock = Instance.new("TextLabel")
	clock.Position = UDim2.new(0, 12, 0, 5)
	clock.Size = UDim2.new(1, -24, 0, 24)
	clock.BackgroundTransparency = 1
	clock.Font = Enum.Font.GothamBold
	clock.TextSize = 20
	clock.TextXAlignment = Enum.TextXAlignment.Left
	clock.TextColor3 = INK
	clock.Text = ""
	clock.Parent = frame

	local feed = Instance.new("TextLabel")
	feed.Position = UDim2.new(0, 12, 0, 30)
	feed.Size = UDim2.new(1, -24, 0, 16)
	feed.BackgroundTransparency = 1
	feed.Font = Enum.Font.GothamBold
	feed.TextSize = 11
	feed.TextXAlignment = Enum.TextXAlignment.Left
	feed.TextColor3 = DIMMED
	feed.Text = ""
	feed.Parent = frame
	return {frame = frame, clock = clock, feed = feed}
end

local function formatClock(sec)
	sec = math.max(0, math.ceil(sec))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local function refreshStatus()
	if not statusUi then
		return
	end
	local state = Obby:GetAttribute("RunState")
	local endsAt = Obby:GetAttribute("RunEndsAt")
	local clock = statusUi.clock
	clock.TextColor3 = INK
	if state == "Won" then
		clock.Text = "RUN CLEAR"
		clock.TextColor3 = TONE.ok
	elseif state == "Lost" then
		clock.Text = "RUN OVER"
		clock.TextColor3 = TONE.danger
	elseif state ~= nil and type(endsAt) == "number" then
		local left = endsAt - Workspace:GetServerTimeNow()
		clock.Text = "RUN " .. formatClock(left) .. (state == "Ready" and "   READY" or "")
		if left < 30 then
			clock.TextColor3 = TONE.danger
		end
	else
		clock.Text = "ROBO OBBY"
	end

	local feedMode = Obby:GetAttribute("FeedMode") or (status and status.feedMode)
	local feed = statusUi.feed
	if feedMode == "live" and status and status.linkOnline == false then
		feed.Text = "ROBOT LINK OFFLINE"
		feed.TextColor3 = TONE.danger
	elseif feedMode == "live" then
		feed.Text = "LIVE ROBOT   -   your cubes place the crates"
		feed.TextColor3 = WANT
	elseif feedMode == "solo" then
		feed.Text = "SOLO   -   the runner places the crates"
		feed.TextColor3 = TONE.warn
	else
		feed.Text = ""
	end
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "OverseerCam"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true

	banner = Instance.new("TextLabel")
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

	sub = Instance.new("TextLabel")
	sub.AnchorPoint = Vector2.new(0.5, 1)
	sub.Position = UDim2.new(0.5, 0, 1, -12)
	sub.Size = UDim2.new(0, 460, 0, 18)
	sub.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
	sub.BackgroundTransparency = 0.25
	sub.BorderSizePixel = 0
	sub.Font = Enum.Font.Gotham
	sub.TextSize = 12
	sub.TextColor3 = Color3.fromRGB(176, 186, 202)
	sub.Text = ""
	sub.Parent = gui
	Instance.new("UICorner", sub).CornerRadius = UDim.new(0, 5)

	xrayBtn = ctrlButton("WALLS: SEE-THROUGH  (G)", 18)
	recenterBtn = ctrlButton("RECENTER VIEW", 52)

	----------------------------------------------------------------
	-- Mini grid. The same 4x3 the operator has in front of them on the table, in the same
	-- orientation, so what is on screen and what they reach for line up without translating.
	----------------------------------------------------------------
	gridFrame = Instance.new("Frame")
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

	cellBtns = {}
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

	objectiveUi = buildObjective(gui)
	statusUi = buildStatus(gui)

	gui.Parent = player:WaitForChild("PlayerGui")
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
	local bay = warehouse and warehouse:FindFirstChild(("Bay%02d"):format(activeBay))
	local anchors = bay and bay:FindFirstChild("CrateAnchors")
	if not (anchors and overlay) then
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
	if not warehouse then
		return -- the map has not streamed in yet; the paint loop re-applies this when it does
	end

	local shell = warehouse:FindFirstChild("Shell")
	for _, p in ipairs(shell and shell:GetChildren() or {}) do
		ghost(p, 0.92)
	end

	-- The roof trusses sit at y = 46, between a 62-stud camera and the floor, and laid two
	-- black bars straight across the bay. The rail beams are left alone: they are thin, they
	-- are where the crane actually rides, and seeing the crane is useful.
	local rails = warehouse:FindFirstChild("SkyRails")
	for _, p in ipairs(rails and rails:GetChildren() or {}) do
		if p.Name:match("^Truss") then
			ghost(p, 1)
		end
	end

	-- The crane hangs directly over the bay and is the single biggest thing between this
	-- camera and the floor. Faded rather than hidden: where the jaw is still tells the
	-- operator what the arm is doing. (SkyArm builds the rig inside the map in the arcade.)
	local rig = map and map:FindFirstChild("SkyArmRig")
	for _, p in ipairs(rig and rig:GetDescendants() or {}) do
		ghost(p, 0.75)
	end

	-- Backdrop scenery over the course -- the hall's roof deck, skylight and arch ribs --
	-- carries the "OverseerHide" tag instead of being enumerated here: the generators in
	-- build/ own the tag, this script just honours it. Hidden outright (not faded) because
	-- at zoom-out the camera rises to ~143 and all of it sits between camera and floor.
	-- Only the obby's own: another game's map may use the tag too.
	for _, p in ipairs(CollectionService:GetTagged("OverseerHide")) do
		if map and p:IsDescendantOf(map) then
			ghost(p, 1)
		end
	end

	-- The bay's own box. Matched by NAME rather than by size or position, because a bay builds
	-- whatever it needs and only its walls and roof should disappear -- the obstacle itself has
	-- to stay visible, which is the entire point of looking.
	local bay = warehouse:FindFirstChild(("Bay%02d"):format(activeBay))
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
-- The robot role has no character of its own: the runner is the player role (Core.Roles), or,
-- with no roles assigned, whoever else has a body.
local function runnerCharacter()
	local fallback = nil
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p.Character then
			if p:GetAttribute("Role") == "player" then
				return p.Character
			end
			fallback = fallback or p.Character
		end
	end
	return fallback
end

local function setHighlight(on)
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	if not on then
		return
	end
	local ch = runnerCharacter()
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
	local ch = runnerCharacter()
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return nil
	end
	local zStart = bayZStart(activeBay)
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
	local zStart = bayZStart(activeBay)
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
	cam.CameraType = Enum.CameraType.Scriptable
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

-- On only at enter, off only at exit: the robot never hands the camera to a runner of its own.
-- Off leaves the camera alone; exit puts back the one it saved.
local function setActive(on)
	active = on
	if on then
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
	end
end

local function refreshBanner()
	if not (banner and sub) then
		return
	end
	banner.Text = ("OVERSEER VIEW   -   BAY %02d   -   %s"):format(activeBay, bayName:upper())
	local n = #(solveCells or {})
	sub.Text = ("%s   -   scroll or -/= zoom, right-drag pan, G walls %s"):format(
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

local ACTION_ZOOM, ACTION_XRAY = "OverseerZoom", "OverseerXray"

local function bindActions()
	ContextActionService:BindActionAtPriority(ACTION_ZOOM, function(_, state, input)
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

	ContextActionService:BindActionAtPriority(ACTION_XRAY, function(_, state)
		if not active then
			return Enum.ContextActionResult.Pass
		end
		if state == Enum.UserInputState.Begin then
			setXray(not xray)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.G)
end

local resetToken = nil

local function onStatus(s)
	if type(s) ~= "table" then
		return
	end
	status = s
	-- A full reset puts the course back to bay 1, which usually reads as a bay change -- but
	-- not when you full-reset while already on bay 1, and then the camera kept whatever zoom
	-- and pan the last run left it with. The token changes either way.
	local wasReset = resetToken ~= nil and s.resetToken ~= resetToken
	resetToken = s.resetToken

	local moved = s.activeBay ~= activeBay or wasReset
	activeBay = s.activeBay or activeBay
	local info = s.bays and s.bays[activeBay]
	solveCells = info and info.solveCells or nil
	bayName = info and info.obstacle or "?"
	if moved then
		occupied = {}
		zoom, panX, panZ = 1, 0, 0    -- a new bay gets the default framing back
	end
	refreshBanner()
	refreshStatus()
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
end

-- The map is cloned in by the mode each round and streams in as one piece (Persistent). Found
-- (or lost) here, from the paint loop, so enter never waits on it.
local function findMap()
	local m = Workspace:FindFirstChild(MAP_NAME)
	local w = m and m:FindFirstChild("Warehouse")
	if w == warehouse and m == map then
		return
	end
	ghostWalls(false)     -- whatever was ghosted belonged to the old map
	map, warehouse = m, w
	if active then
		ghostWalls(xray)
		buildMarkers()    -- clears the old map's markers too, when there is no new one
		paintGrid()
		if warehouse then
			Status:FireServer() -- the bay and its wanted cells, now that there is a bay to mark
		end
	end
end

function RobotView.enter(_ctx)
	RobotView.exit()
	generation += 1
	local myGeneration = generation

	-- Core RoleClient has already made the robot's camera Scriptable; saved anyway, so exit hands
	-- back exactly what enter found (FloodRobotView's pattern).
	local cam = Workspace.CurrentCamera
	savedCamera = {camera = cam, type = cam.CameraType, cframe = cam.CFrame, fov = cam.FieldOfView}
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = FOV

	overlay = Instance.new("Folder")
	overlay.Name = "OverseerOverlay"
	overlay.Parent = Workspace

	buildGui()
	setXray(xray)
	refreshStatus()

	bindActions()

	track(xrayBtn.MouseButton1Click:Connect(function()
		setXray(not xray)
	end))

	track(recenterBtn.MouseButton1Click:Connect(function()
		zoom, panX, panZ = 1, 0, 0
		aimCamera()
	end))

	track(Status.OnClientEvent:Connect(onStatus))

	track(BayCells.OnClientEvent:Connect(function(bayIndex, cellsList)
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
	end))

	track(Objective.OnClientEvent:Connect(function(p)
		if objectiveUi then
			showObjective(objectiveUi, p)
		end
	end))

	for _, name in ipairs({"RunState", "RunEndsAt", "FeedMode"}) do
		track(Obby:GetAttributeChangedSignal(name):Connect(refreshStatus))
	end

	track(UserInputService.InputBegan:Connect(function(input)
		-- Right button starts a pan. The processed guard is skipped on purpose: the operator
		-- grabs the view by dragging over the middle of the screen, and the objective panel and
		-- the mini grid both sit in that space.
		if active and input.UserInputType == Enum.UserInputType.MouseButton2 then
			panning = true
		end
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			panning = false
		end
	end))

	-- Right-drag to pan. No processed guard: the drag starts over the middle of the screen,
	-- where the objective panel and the mini grid both live. (Zoom is a bound action, above.)
	track(UserInputService.InputChanged:Connect(function(input)
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
	end))

	-- The camera is re-asserted every frame rather than only when it moves: Roblox hands the
	-- camera back to the default scripts on a few CoreGui transitions, and a one-shot CFrame
	-- would silently lose the view.
	track(RunService.RenderStepped:Connect(function()
		if active then
			aimCamera()
		end
	end))

	findMap()
	setActive(true)

	-- The runner's cell changes as they move, which no event reports. The same beat finds the map
	-- once it streams in, re-outlines the runner after a respawn (the highlight dies with the old
	-- character) and ticks the run clock.
	task.spawn(function()
		while generation == myGeneration do
			if active then
				findMap()
				local ch = runnerCharacter()
				if ch and not (highlight and highlight.Parent == ch) then
					setHighlight(true)
				end
				paintGrid()
				refreshStatus()
			end
			task.wait(0.25)
		end
	end)

	Status:FireServer()
	print("[RobotView] overseer view on")
end

function RobotView.exit()
	generation += 1 -- stops the paint loop
	setActive(false)
	ContextActionService:UnbindAction(ACTION_ZOOM)
	ContextActionService:UnbindAction(ACTION_XRAY)
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	if overlay then
		overlay:Destroy()
		overlay = nil
	end
	if gui then
		gui:Destroy()
		gui, banner, sub, gridFrame, xrayBtn, recenterBtn = nil, nil, nil, nil, nil, nil
		objectiveUi, statusUi = nil, nil
		cellBtns = {}
	end
	map, warehouse, status, resetToken = nil, nil, nil, nil
	occupied, solveCells, bayName = {}, nil, "?"
	activeBay = Config.LiveBay or 1
	zoom, panX, panZ = 1, 0, 0
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

return RobotView
