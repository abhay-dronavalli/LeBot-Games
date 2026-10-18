-- ReplicatedStorage.Obby.Views.RobotView (ModuleScript)
-- Robo Obby's robot view (Core.Games.Obby): what the operator at the real arm sees while the Obby is the
-- active game. The arcade port of lebot_obby/StarterPlayerScripts/OverseerCam.client.lua (Kushagra's
-- overseer view, his notes kept below), turned into enter(ctx) / exit():
--   * enter builds the panels and the overlay and turns the overseer view ON at once. The robot role has
--     no runner of its own to flip back to, so there is no V key. Zoom (wheel, - / =), right-drag pan, G
--     walls and the two buttons stay: they are the operator's controls.
--   * the robot has NO character. The "runner" it outlines and tracks on the mat grid is the player whose
--     Role attribute is "player" (fallback: any other player with a character).
--   * the world is workspace.ObbyMap (cloned in each round, ModelStreamingMode Persistent). It is waited for
--     by the paint loop, not by enter, so enter never holds up Core RoleClient; the bays sit Config.OriginZ
--     down +Z, so every Z worked out from a bay index adds it (bayZStart).
--   * Remotes.Status (activeBay, solveCells, level, resetToken, feedMode, linkOnline) and Remotes.BayCells
--     (the occupied cells) drive his order card and the mat grid; Remotes.Objective (the runner's task,
--     copied to the robot by the server, the win / lose screens included) shows top centre in his
--     ObjectiveHud order-board look. A status panel top left, under the Roblox top bar: the run clock
--     (ReplicatedStorage.Obby RunEndsAt / RunState), the feed mode, and ROBOT LINK OFFLINE when the feed
--     is live and the core link is down. His card, mat and buttons own the right-hand column; the two
--     arcade panels stay left of it and clear of it down to a 1024-wide screen.
--   * exit disconnects everything, stops the paint loop, puts back every LocalTransparencyModifier it
--     ghosted, destroys the overlay, the highlight and the GUI, unbinds its actions and puts the camera back
--     (FloodRobotView's savedCamera). Never touches Lighting.
--
-- OverseerCam (client) -- player 2's view of the bay.
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
local Ui = require(Obby:WaitForChild("UiTheme"))

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

local INK = Ui.C.parchment
local WANT = Ui.C.amber        -- the cell being asked for RIGHT NOW
local HELD = Ui.C.ok           -- already filled
local RUNNER = Ui.C.info       -- where player 1 is standing
local DIMMED = Ui.C.ghost

-- Arcade panels. His right-hand column (buttons, order card, mat) is 250 wide at 18 from the right
-- edge; the objective board is centred and the status panel sits top left, and both are sized so
-- neither reaches that column on a 1024-wide screen (460 + 2 * (250 + 18 + 12) = 1020).
local OBJ_W = 460
local OBJ_TOP = 16
local STATUS_W, STATUS_H = 250, 80
local STATUS_TOP = 64      -- under the Roblox top bar's buttons (the gui ignores the inset)
local TOAST_LIFE = 4.5     -- as ObjectiveHud's toasts: long enough to read a sentence

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
local bayLevel = nil          -- cubes per cell, for the order card
local occupied = {}
local markers = {}
local hidden = {}          -- part -> its real LocalTransparencyModifier
local highlight = nil
local status = nil         -- the last Remotes.Status payload

-- Built by buildGui at enter, dropped by exit.
local overlay
local gui, banner, sub, gridFrame
local card, crateHolder, colLabel, rowLabel, qtyLabel, progressLabel
local cellBtns = {}
local objectiveUi, statusUi

local function drawCrate(count)
	if not crateHolder then
		return
	end
	crateHolder:ClearAllChildren()
	if count and count > 0 then
		Ui.crateIcon(crateHolder, {count = count, anchor = Vector2.new(0.5, 1),
			position = UDim2.new(0.5, 0, 1, 0), size = UDim2.fromOffset(40, 58)})
	end
end

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

----------------------------------------------------------------
-- The objective board (arcade)
----------------------------------------------------------------
-- The runner's task, ported from Views.Player.ObjectiveHud's order board (same look, same place:
-- top centre). The camera already aims past the bay's middle to keep the grid out from under it,
-- which is the layout this view was built around when the runner's HUD shared the screen. The
-- mode's win / lose screens arrive here too, as ordinary payloads.
-- Payload: {title, task, hint, tone, timer, timerLabel, timerTone, flash, steps, note}
-- `flash` is raised as one toast under the board, edge-detected like ObjectiveHud's (it persists in
-- every later push, so showing it while present would never take it down).
local function buildObjective(parent)
	local board = Ui.panel({
		parent = parent,
		name = "Objective",
		title = "",
		size = UDim2.fromOffset(OBJ_W, 140),
		position = UDim2.new(0.5, 0, 0, OBJ_TOP),
		anchor = Vector2.new(0.5, 0),
		tone = "danger",
		zindex = 2,
	})
	board.frame.Visible = false

	local taskLabel = Ui.text(board.body, {style = "task", text = "", size = UDim2.new(1, 0, 0, 32)})
	local hintLabel = Ui.text(board.body, {style = "hint", text = "",
		position = UDim2.fromOffset(0, 34), size = UDim2.new(1, 0, 0, 18), wrap = true})

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

	-- the flash toast: ObjectiveHud's toast look, one slot, under the board
	local toast = Instance.new("Frame")
	toast.Name = "Flash"
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.new(0.5, 0, 0, OBJ_TOP + 150)
	toast.Size = UDim2.fromOffset(OBJ_W - 40, 32)
	toast.BackgroundColor3 = Ui.C.iron
	toast.BackgroundTransparency = 0.08
	toast.BorderSizePixel = 0
	toast.ZIndex = 5
	toast.Visible = false
	toast.Parent = parent
	Ui.corner(toast, 4)
	Ui.stroke(toast, Ui.C.warn, 1.5)
	Ui.sheen(toast, 0.25)

	local tab = Instance.new("Frame")
	tab.Size = UDim2.new(0, 4, 1, -10)
	tab.Position = UDim2.fromOffset(5, 5)
	tab.BackgroundColor3 = Ui.C.warn
	tab.BorderSizePixel = 0
	tab.ZIndex = 6
	tab.Parent = toast
	Ui.corner(tab, 2)

	local toastLabel = Ui.text(toast, {style = "step", text = "", textSize = 14,
		colour = Ui.C.parchment, position = UDim2.fromOffset(18, 0),
		size = UDim2.new(1, -26, 1, 0), zindex = 6})

	return {
		board = board, task = taskLabel, hint = hintLabel,
		timerBox = timerBox, timerCaption = timerCaption, timerValue = timerValue,
		steps = stepLabels, note = noteLabel,
		toast = toast, toastLabel = toastLabel, toastToken = 0, lastFlash = nil,
	}
end

local function showObjective(ui, p)
	if not p then
		ui.board.frame.Visible = false
		ui.toast.Visible = false
		ui.lastFlash = nil
		return
	end

	ui.board.frame.Visible = true
	ui.board.setTone(p.tone)
	ui.board.setTitle(p.title or "")
	ui.task.Text = p.task or ""
	ui.task.TextColor3 = Ui.tone(p.tone, Ui.C.amber)
	ui.hint.Text = p.hint or ""

	local y = 58
	if p.timer then
		ui.timerCaption.Text = p.timerLabel or ""
		-- whole seconds only; a ticking fraction reads as noise at this size
		local secs = math.max(0, math.floor(p.timer + 0.5))
		ui.timerValue.Text = string.format("%d:%02d", math.floor(secs / 60), secs % 60)
		ui.timerValue.TextColor3 = (p.timerTone and Ui.tone(p.timerTone))
			or (secs <= 10 and Ui.C.danger)
			or Ui.C.parchment
		ui.timerBox.Position = UDim2.new(0.5, 0, 0, y)
		ui.timerBox.Visible = true
		y += 48
	else
		ui.timerBox.Visible = false
	end

	local used = 0
	for idx, l in ipairs(ui.steps) do
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

	ui.note.Visible = p.note ~= nil
	if p.note then
		ui.note.Text = p.note
		ui.note.Position = UDim2.fromOffset(4, y)
		y += 32
	end

	local height = math.max(120, y + 34)
	ui.board.frame.Size = UDim2.fromOffset(OBJ_W, height)
	ui.toast.Position = UDim2.new(0.5, 0, 0, OBJ_TOP + height + 10)

	if p.flash and p.flash ~= ui.lastFlash then
		ui.toastToken += 1
		local mine = ui.toastToken
		ui.toastLabel.Text = tostring(p.flash):upper()
		ui.toast.Visible = true
		task.delay(TOAST_LIFE, function()
			if ui.toastToken == mine and ui.toast.Parent then
				ui.toast.Visible = false
			end
		end)
	end
	ui.lastFlash = p.flash
end

----------------------------------------------------------------
-- The status panel (arcade)
----------------------------------------------------------------
-- Top left: the run clock and who owns the crates this round. The accent bar carries the feed
-- state, so a dead robot link reads before any word does.
local function buildStatus(parent)
	local panel = Ui.panel({
		parent = parent,
		name = "RunStatus",
		size = UDim2.fromOffset(STATUS_W, STATUS_H),
		position = UDim2.fromOffset(18, STATUS_TOP),
		tone = "info",
		zindex = 3,
	})
	local clock = Ui.text(panel.body, {style = "number", text = "", textSize = 22,
		align = Enum.TextXAlignment.Left, size = UDim2.new(1, 0, 0, 24)})
	local feed = Ui.text(panel.body, {style = "caption", text = "",
		position = UDim2.fromOffset(0, 24), size = UDim2.new(1, 0, 0, 14)})
	local detail = Ui.text(panel.body, {style = "note", text = "", align = Enum.TextXAlignment.Left,
		position = UDim2.fromOffset(0, 38), size = UDim2.new(1, 0, 0, 14)})
	return {panel = panel, clock = clock, feed = feed, detail = detail}
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
	clock.TextColor3 = Ui.C.parchment
	if state == "Won" then
		clock.Text = "RUN CLEAR"
		clock.TextColor3 = Ui.C.ok
	elseif state == "Lost" then
		clock.Text = "RUN OVER"
		clock.TextColor3 = Ui.C.danger
	elseif state ~= nil and (type(endsAt) == "number" or Obby:GetAttribute("RunSeconds")) then
		local left = type(endsAt) == "number" and (endsAt - Workspace:GetServerTimeNow())
			or Obby:GetAttribute("RunSeconds")
		clock.Text = "RUN " .. formatClock(left) .. (state == "Ready" and "   READY" or "")
		if left < 30 then
			clock.TextColor3 = Ui.C.danger
		end
	else
		clock.Text = "ROBO OBBY"
		clock.TextColor3 = Ui.C.amber
	end

	local feedMode = Obby:GetAttribute("FeedMode") or (status and status.feedMode)
	local feed, detail = statusUi.feed, statusUi.detail
	if feedMode == "live" and status and status.linkOnline == false then
		statusUi.panel.setTone("danger")
		feed.Text = "ROBOT LINK OFFLINE"
		feed.TextColor3 = Ui.C.danger
		detail.Text = "the arm is not reaching the game"
	elseif feedMode == "live" then
		statusUi.panel.setTone("ok")
		feed.Text = "LIVE ROBOT"
		feed.TextColor3 = Ui.C.ok
		detail.Text = "your cubes place the crates"
	elseif feedMode == "solo" then
		statusUi.panel.setTone("warn")
		feed.Text = "SOLO"
		feed.TextColor3 = Ui.C.warn
		detail.Text = "the runner places the crates"
	else
		statusUi.panel.setTone("info")
		feed.Text = ""
		detail.Text = ""
	end
end

----------------------------------------------------------------
-- Panel
----------------------------------------------------------------
local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "OverseerCam"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 12

	----------------------------------------------------------------
	-- THE ORDER CARD. The most important thing on player 2's screen.
	----------------------------------------------------------------
	-- Player 2's entire job is "put a cube on the mat at the right square". Everything they need
	-- for that is one coordinate and one quantity, and it used to be spelled out nowhere -- the
	-- old panel said "2 cells want a block" and left them to find which two on a 4x3 of
	-- identically-styled squares. This card answers it directly, in the largest type on screen,
	-- and the mat below is now the confirmation rather than the instruction.
	card = Ui.panel({
		parent = gui,
		name = "OrderCard",
		title = "NEXT BLOCK",
		size = UDim2.fromOffset(250, 150),
		position = UDim2.new(1, -18, 0, 92),
		anchor = Vector2.new(1, 0),
		tone = "ok",
		zindex = 3,
	})

	crateHolder = Instance.new("Frame")
	crateHolder.BackgroundTransparency = 1
	crateHolder.Size = UDim2.fromOffset(52, 62)
	crateHolder.Position = UDim2.fromOffset(0, 2)
	crateHolder.ZIndex = card.body.ZIndex + 1
	crateHolder.Parent = card.body
	drawCrate(1)

	-- The coordinate, as big as it will go. Two lines, because "COL 1 ROW 0" on one line reads as
	-- a single four-token string the operator has to parse; stacked, it is two facts.
	colLabel = Ui.text(card.body, {style = "task", text = "--", textSize = 30,
		align = Enum.TextXAlignment.Left, position = UDim2.fromOffset(62, 2),
		size = UDim2.new(1, -62, 0, 32)})
	rowLabel = Ui.text(card.body, {style = "task", text = "", textSize = 30,
		align = Enum.TextXAlignment.Left, position = UDim2.fromOffset(62, 32),
		size = UDim2.new(1, -62, 0, 32)})

	qtyLabel = Ui.text(card.body, {style = "caption", text = "",
		align = Enum.TextXAlignment.Center, position = UDim2.fromOffset(0, 70),
		size = UDim2.new(1, 0, 0, 14)})
	Ui.rule(card.body, 88, 4)
	progressLabel = Ui.text(card.body, {style = "hint", text = "", textSize = 13,
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
	gridFrame = matPanel.body

	cellBtns = {}
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
	banner = Ui.text(bannerPanel.body, {style = "title", text = "OVERSEER VIEW",
		textSize = 17, colour = Ui.C.amber, size = UDim2.new(1, 0, 0, 20)})
	sub = Ui.text(bannerPanel.body, {style = "hint", text = "", textSize = 11,
		position = UDim2.fromOffset(0, 20), size = UDim2.new(1, 0, 0, 14)})

	xrayBtn = ctrlButton("WALLS: SEE-THROUGH  (G)", 18)
	recenterBtn = ctrlButton("RECENTER VIEW", 52)

	objectiveUi = buildObjective(gui)
	statusUi = buildStatus(gui)

	gui.Parent = player:WaitForChild("PlayerGui")
end

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
	if not card then
		return
	end
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
		if not isNext then
			-- the pulse below only ever writes the next cell; one that stops being next keeps
			-- whatever fade it was left at unless it is put back here
			c.stroke.Transparency = 0
		end

		-- the runner's square is marked on top of whatever it already is
		if isHere then
			c.stroke.Color = RUNNER
			c.stroke.Thickness = 3
		end
	end

	refreshCard()
end

-- On only at enter, off only at exit: the robot never hands the camera to a runner of its own.
-- Off leaves the camera alone; exit puts back the one it saved.
local function setActive(on)
	active = on
	if gui then
		gui.Enabled = on
	end
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
	sub.Text = ("scroll or -/= zoom   .   right-drag pan   .   G walls %s")
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
	bayLevel = info and info.level or nil
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
		card, crateHolder, colLabel, rowLabel, qtyLabel, progressLabel = nil, nil, nil, nil, nil, nil
		objectiveUi, statusUi = nil, nil
		cellBtns = {}
	end
	map, warehouse, status, resetToken = nil, nil, nil, nil
	occupied, solveCells, bayName, bayLevel, nextKey = {}, nil, "?", nil, nil
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
