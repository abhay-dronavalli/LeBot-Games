--!strict
-- The arena HUD, and the operator's overhead view. A LocalScript in StarterPlayerScripts.
--
-- Layout follows concepts/refs/slam.png: survivors pill top left, timer top centre with the active
-- effect chips under it, ability bar bottom right. Banners come and go in the centre. Nothing else
-- stays on screen - the scene behind it is busy, and the dragon is the thing to watch.
--
-- THE HUD DECIDES NOTHING. Every number here arrives in the Hud payload from the server. The timer
-- is not counted locally, and the effect chips show `state.effects[].remaining` - the server's
-- clamped value - because a HUD running its own timer drifts and then lies about a debuff that
-- already ended (hard rule 4).
--
-- NO PLAYER-PUNISHING EFFECTS. The debuffs belong to the players, so they never flip this screen,
-- fog it, or shake it. The one thing that does shake the camera is a slam, which is the dragon's
-- doing (style guide section 8).
--
-- Sizes are in Scale where it matters and the slots never drop below 56 px, so the bar stays
-- usable at phone width.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage:WaitForChild("Arena"):WaitForChild("Theme"))
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Remotes = require(ReplicatedStorage.Arena.Remotes)

local C = Theme.Color
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local gui = Instance.new("ScreenGui")
gui.Name = "ArenaHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

-- Small screens. Everything below is laid out at desktop sizes and then scaled as one, so the
-- proportions survive a phone instead of each element needing its own breakpoint. The scale has a
-- floor, and the ability slots have their own minimum below, because a slot that scales down past
-- about 56 px stops being tappable.
local uiScale = Instance.new("UIScale")
uiScale.Parent = gui

local function fitViewport()
	local v = camera.ViewportSize
	-- 1280 wide is the layout's reference width. Narrower screens shrink, wider ones do not grow:
	-- a HUD that scales up on a big monitor just eats the view of the arena.
	uiScale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.62, 1)
end

fitViewport()
camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitViewport)

-- Every text element gets an ink stroke: the scene behind it is lava and fire, and unstroked white
-- text disappears over the bright parts.
local function stroke(label: TextLabel, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = C.UiInk
	s.Thickness = thickness or 2
	s.Parent = label
end

local function text(parent: Instance, font: Font, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.TextSize = size
	l.TextColor3 = color
	l.Parent = parent
	stroke(l, size > 40 and 3 or 2)
	return l
end

local function panel(parent: Instance): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = C.UiInk
	f.BackgroundTransparency = 0.35
	f.BorderSizePixel = 0
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = f
	return f
end

-- ---------------------------------------------------------------------------------------------
-- Top left: survivors
-- ---------------------------------------------------------------------------------------------

local survivorsPill = panel(gui)
survivorsPill.Position = UDim2.new(0, 16, 0, 16)
survivorsPill.Size = UDim2.new(0, 150, 0, 48)

local survivorsLabel = text(survivorsPill, Theme.Font.Label, 16, C.UiText)
survivorsLabel.Position = UDim2.new(0, 12, 0, 6)
survivorsLabel.Size = UDim2.new(1, -24, 0, 16)
survivorsLabel.TextXAlignment = Enum.TextXAlignment.Left
survivorsLabel.Text = "SURVIVORS"

local survivorsCount = text(survivorsPill, Theme.Font.Display, 20, C.UiText)
survivorsCount.Position = UDim2.new(0, 12, 0, 24)
survivorsCount.Size = UDim2.new(1, -24, 0, 20)
survivorsCount.TextXAlignment = Enum.TextXAlignment.Left
survivorsCount.Text = "0/0"

-- ---------------------------------------------------------------------------------------------
-- Top centre: timer and the active effect chips
-- ---------------------------------------------------------------------------------------------

local timer = text(gui, Theme.Font.Display, 48, C.UiText)
timer.AnchorPoint = Vector2.new(0.5, 0)
timer.Position = UDim2.new(0.5, 0, 0, 10)
timer.Size = UDim2.new(0, 200, 0, 56)
timer.Text = "0:00"

local chipRow = Instance.new("Frame")
chipRow.BackgroundTransparency = 1
chipRow.AnchorPoint = Vector2.new(0.5, 0)
chipRow.Position = UDim2.new(0.5, 0, 0, 68)
chipRow.Size = UDim2.new(0, 460, 0, 28)
chipRow.Parent = gui

local chipLayout = Instance.new("UIListLayout")
chipLayout.FillDirection = Enum.FillDirection.Horizontal
chipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
chipLayout.Padding = UDim.new(0, 6)
chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
chipLayout.Parent = chipRow

-- One chip per active effect: icon, seconds remaining, border in the effect's colour. Rebuilt from
-- the payload each tick rather than diffed - at most six chips, so the churn is not worth the
-- bookkeeping.
local function drawChips(effects: { any })
	for _, child in chipRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i, e in effects do
		local chip = panel(chipRow)
		chip.Size = UDim2.new(0, 96, 1, 0)
		chip.LayoutOrder = i
		local border = Instance.new("UIStroke")
		border.Color = e.color
		border.Thickness = 2
		border.Parent = chip

		local label = text(chip, Theme.Font.Label, 13, e.color)
		label.Position = UDim2.new(0, 6, 0, 0)
		label.Size = UDim2.new(1, -12, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = ("%s %ds"):format(e.label, math.ceil(e.remaining))
	end
end

-- ---------------------------------------------------------------------------------------------
-- Bottom right: the ability bar
-- ---------------------------------------------------------------------------------------------

-- 64 px at full scale. `fitSlots` below keeps the rendered size at or above SLOT_MIN_PX by
-- compensating for the global UIScale, because the style guide's floor is a *touch target*, and a
-- target that shrinks with the rest of the HUD stops being one.
local SLOT_PX = 64
local SLOT_MIN_PX = 56

local bar = Instance.new("Frame")
bar.BackgroundTransparency = 1
bar.AnchorPoint = Vector2.new(1, 1)
bar.Position = UDim2.new(1, -16, 1, -16)
bar.Size = UDim2.new(0, (SLOT_PX + 8) * ArenaConfig.ABILITY_SLOTS, 0, SLOT_PX)
bar.Parent = gui

local barLayout = Instance.new("UIListLayout")
barLayout.FillDirection = Enum.FillDirection.Horizontal
barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
barLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
barLayout.Padding = UDim.new(0, 8)
barLayout.SortOrder = Enum.SortOrder.LayoutOrder
barLayout.Parent = bar

local slotTiles = {}
for i = 1, ArenaConfig.ABILITY_SLOTS do
	local tile = panel(bar)
	tile.Size = UDim2.new(0, SLOT_PX, 0, SLOT_PX)
	tile.LayoutOrder = i

	local border = Instance.new("UIStroke")
	border.Color = C.UiText
	border.Thickness = 2
	border.Parent = tile

	local label = text(tile, Theme.Font.Label, 12, C.UiText)
	label.Position = UDim2.new(0, 2, 1, -18)
	label.Size = UDim2.new(1, -4, 0, 16)
	label.Text = ""

	local key = text(tile, Theme.Font.Label, 12, C.UiText)
	key.Position = UDim2.new(0, 4, 0, 2)
	key.Size = UDim2.new(0, 14, 0, 14)
	key.Text = tostring(i)
	key.TextTransparency = 0.4

	-- Cooldown is a bottom-up fill, so a slot visibly comes back rather than just reappearing.
	local cd = Instance.new("Frame")
	cd.BackgroundColor3 = C.UiInk
	cd.BackgroundTransparency = 0.5
	cd.BorderSizePixel = 0
	cd.AnchorPoint = Vector2.new(0, 1)
	cd.Position = UDim2.new(0, 0, 1, 0)
	cd.Size = UDim2.new(1, 0, 0, 0)
	cd.Parent = tile

	local button = Instance.new("TextButton")
	button.BackgroundTransparency = 1
	button.Text = ""
	button.Size = UDim2.new(1, 0, 1, 0)
	button.Parent = tile
	button.Activated:Connect(function()
		Remotes.SlotFire:FireServer(i)
	end)

	slotTiles[i] = { tile = tile, border = border, label = label, cd = cd }
end

local function fitSlots()
	local px = math.max(SLOT_PX, SLOT_MIN_PX / math.max(uiScale.Scale, 0.01))
	for _, t in slotTiles do
		t.tile.Size = UDim2.new(0, px, 0, px)
	end
	bar.Size = UDim2.new(0, (px + 8) * ArenaConfig.ABILITY_SLOTS, 0, px)
end

fitSlots()
camera:GetPropertyChangedSignal("ViewportSize"):Connect(fitSlots)

-- Number keys fire the slots too; the tiles are for touch.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local n = input.KeyCode.Value - Enum.KeyCode.One.Value + 1
	if n >= 1 and n <= ArenaConfig.ABILITY_SLOTS then
		Remotes.SlotFire:FireServer(n)
	end
end)

local function drawSlots(slots: { any })
	for i, tile in slotTiles do
		local s = slots and slots[i]
		if s and s.name then
			-- A slot holding a picked-up debuff carries that effect's colour.
			tile.border.Color = s.color
			tile.border.Thickness = 3
			tile.label.Text = s.label
			tile.label.TextColor3 = s.color
			tile.cd.Size = UDim2.new(1, 0, 0, 0)
		elseif s and s.cooldown then
			tile.border.Color = C.UiText
			tile.border.Thickness = 2
			tile.label.Text = ""
			local f = math.clamp(s.cooldown / ArenaConfig.ABILITY_COOLDOWN_S, 0, 1)
			tile.cd.Size = UDim2.new(1, 0, f, 0)
		else
			-- An empty, ready slot glows Power: cool, because it belongs to the player.
			tile.border.Color = C.Power
			tile.border.Thickness = 3
			tile.label.Text = ""
			tile.cd.Size = UDim2.new(1, 0, 0, 0)
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Banners and the spectate line
-- ---------------------------------------------------------------------------------------------

local banner = text(gui, Theme.Font.Display, 96, C.UiText)
banner.AnchorPoint = Vector2.new(0.5, 0.5)
banner.Position = UDim2.new(0.5, 0, 0.38, 0)
banner.Size = UDim2.new(1, -40, 0, 110)
banner.Text = ""
-- Scaled, with a ceiling: "THE DRAGON WINS" at a fixed 96 px runs off the side of a phone, and
-- TextScaled alone would blow a short word like "3" up to fill the whole band.
banner.TextScaled = true
local bannerMax = Instance.new("UITextSizeConstraint")
bannerMax.MaxTextSize = 96
bannerMax.MinTextSize = 28
bannerMax.Parent = banner

local bannerSub = text(gui, Theme.Font.Label, 20, C.UiText)
bannerSub.AnchorPoint = Vector2.new(0.5, 0.5)
bannerSub.Position = UDim2.new(0.5, 0, 0.38, 70)
bannerSub.Size = UDim2.new(1, -40, 0, 26)
bannerSub.Text = ""

local spectating = text(gui, Theme.Font.Label, 16, C.UiText)
spectating.AnchorPoint = Vector2.new(0.5, 1)
spectating.Position = UDim2.new(0.5, 0, 1, -12)
spectating.Size = UDim2.new(0, 400, 0, 20)
spectating.Text = ""

local bannerToken = 0
Remotes.Banner.OnClientEvent:Connect(function(info)
	bannerToken += 1
	local mine = bannerToken
	banner.Text = info.text
	banner.TextColor3 = info.color
	bannerSub.Text = info.sub or ""
	task.delay(info.seconds or 2, function()
		if bannerToken == mine then
			banner.Text = ""
			bannerSub.Text = ""
		end
	end)
end)

-- ---------------------------------------------------------------------------------------------
-- Camera shake: a slam, and only a slam
-- ---------------------------------------------------------------------------------------------

local shakeUntil = 0
local shakeStrength = 0
-- Declared here, above the RenderStepped closure that reads it. Declaring it further down next to
-- the Hud handler would make that closure capture a global of the same name instead, and the
-- pulse would silently never run.
local timerUrgent = false

Remotes.Shake.OnClientEvent:Connect(function(strength, seconds)
	shakeStrength = math.max(shakeStrength, strength)
	shakeUntil = math.max(shakeUntil, os.clock() + seconds)
end)

RunService.RenderStepped:Connect(function()
	if timerUrgent then
		-- A gentle pulse, not a flash: the last ten seconds should raise the pulse without
		-- competing with the fire for attention.
		timer.TextTransparency = 0.25 + 0.25 * math.sin(os.clock() * 6)
	end
	if os.clock() >= shakeUntil then
		shakeStrength = 0
		return
	end
	-- Offsets the camera's CFrame only; the default third-person camera is left in charge
	-- (style guide section 10), so nothing fights the player's own control.
	local f = (shakeUntil - os.clock())
	local amp = shakeStrength * math.min(f, 0.4) * 6
	camera.CFrame = camera.CFrame * CFrame.new(
		(math.random() - 0.5) * amp,
		(math.random() - 0.5) * amp,
		0)
end)

-- ---------------------------------------------------------------------------------------------
-- The HUD payload
-- ---------------------------------------------------------------------------------------------

Remotes.Hud.OnClientEvent:Connect(function(payload)
	spectating.Text = payload.spectating and ("SPECTATING " .. string.upper(payload.spectating)) or ""

	survivorsCount.Text = ("%d/%d"):format(payload.survivors or 0, payload.total or 0)

	local left = payload.timeLeft or 0
	timer.Text = ("%d:%02d"):format(math.floor(left / 60), math.floor(left % 60))
	-- The pulse itself runs on RenderStepped below. Driving it from this handler would step it at
	-- the payload rate (8 Hz), which reads as a stutter rather than a pulse.
	slamStuds = payload.slamStuds or slamStuds
	timerUrgent = left <= 10 and payload.state == "Round"
	timer.TextColor3 = timerUrgent and C.UiDanger or C.UiText
	if not timerUrgent then
		timer.TextTransparency = 0
	end

	drawChips(payload.effects or {})
	drawSlots(payload.slots or {})
end)

-- ---------------------------------------------------------------------------------------------
-- The aerial operator view
-- ---------------------------------------------------------------------------------------------

-- Press V to switch any client between the normal player camera and the aerial view. The server
-- can also assign it on join (the ArenaOperator attribute, set from OPERATOR_NAME in ArenaMain),
-- but the key is the one that always works: in Play Solo your player is named after your Roblox
-- account, not "Player1", so a name match is exactly the thing that fails when you are trying to
-- get a second screen up in a hurry.
local AERIAL_KEY = Enum.KeyCode.V

local OPERATOR_FACING = {
	mirror = "CONTROLS INVERTED",
	fog = "CONTROLS LAGGING",
	molasses = "CONTROLS SLUGGISH",
	freeze = "ARM FROZEN",
	earthquake = "ARM SHAKING",
	butterfingers = "JAW JAMMED",
}

-- Debuffs that change what the operator's own hands are doing, shown large because they are the
-- reason the arm is not going where they pushed it.
local opText = text(gui, Theme.Font.Display, 40, C.UiDanger)
opText.AnchorPoint = Vector2.new(0.5, 0)
opText.Position = UDim2.new(0.5, 0, 0, 110)
opText.Size = UDim2.new(1, -40, 0, 50)
opText.Text = ""
opText.Visible = false

local hint = text(gui, Theme.Font.Label, 14, C.UiText)
hint.AnchorPoint = Vector2.new(1, 0)
hint.Position = UDim2.new(1, -16, 0, 16)
hint.Size = UDim2.new(0, 220, 0, 18)
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.TextTransparency = 0.35
hint.Text = "V — AERIAL VIEW"

local aerial = false
local highlights = {} :: { [Model]: Highlight }
local aerialConns = {} :: { RBXScriptConnection }
local aerialView: CFrame? = nil

-- Dark avatars vanish against obsidian from overhead, and the operator has to see who they are
-- about to land a head on. Only the aerial view outlines them; the players never see this.
local function mark(char: Model)
	if not aerial or highlights[char] then
		return
	end
	local h = Instance.new("Highlight")
	h.OutlineColor = C.UiText
	h.FillTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Adornee = char
	h.Parent = char
	highlights[char] = h
end

local function clearMarks()
	for char, h in highlights do
		h:Destroy()
		highlights[char] = nil
	end
end

-- Where to put the camera. Nil until the arena exists, which only happens once `hello` arrives -
-- so this is recomputed on each toggle rather than cached from the first attempt.
local function aerialCFrame(): CFrame?
	local arenaModel = workspace:FindFirstChild("Arena")
	local floor = arenaModel and arenaModel:FindFirstChild("Floor")
	if not (floor and floor:IsA("BasePart")) then
		return nil
	end
	local centre = floor.Position
	-- Fractions of the floor's own size, not fixed studs, so the framing survives a change to
	-- ARENA_SCALE. Both live in ArenaConfig - turn AERIAL_HEIGHT_FRAC down to come in closer.
	local span = math.max(floor.Size.X, floor.Size.Z)
	local height = span * ArenaConfig.AERIAL_HEIGHT_FRAC
	-- Pulled back toward the far edge and tilted, not straight down: a pure top-down view hides
	-- how high the head is, which is the one thing the operator needs to judge.
	local back = floor.Size.Z * ArenaConfig.AERIAL_BACK_FRAC
	return CFrame.lookAt(centre + Vector3.new(0, height, back), centre)
end

-- ---------------------------------------------------------------------------------------------
-- The operator's aiming aids
--
-- The operator flies a real 3D arm from a flat overhead view. From up there, "directly above that
-- player" and "thirty studs short of them" look the same, and there is no cue at all for height -
-- so without help they are aiming blind, which is not a skill problem to be overcome.
--
-- This does not break hard rule 1. That rule forbids telegraphs on the PLAYERS' screens, so that
-- players dodge by watching the dragon instead of reading a marker that says where the strike will
-- land. Everything below shows where the jaw is RIGHT NOW - the same class of thing as the
-- dragon's own shadow, which rule 1 explicitly allows - and all of it is built here, on the
-- operator's client, so it does not replicate and no player ever sees it.
--
-- Three cues, because they answer three different questions:
--   the disc    - where on the floor am I? turns red when a player is under me
--   the line    - how high am I? its length IS the height, which is the cue overhead view destroys
--   the readout - the numbers, plus who I am over
-- ---------------------------------------------------------------------------------------------

local aim = nil :: any
local slamStuds = 5          -- replaced by the server's converted figure on the first payload

local function buildAim()
	local folder = Instance.new("Folder")
	folder.Name = "OperatorAim"
	folder.Parent = workspace

	local function fx(name: string, size: Vector3, colour: Color3, shape: Enum.PartType?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.Neon
		p.Color = colour
		p.Size = size
		if shape then
			p.Shape = shape
		end
		p.Parent = folder
		return p
	end

	local disc = fx("Disc", Vector3.new(0.4, 1, 1), C.DragonEye, Enum.PartType.Cylinder)
	disc.Transparency = 0.72
	local dot = fx("Dot", Vector3.new(0.5, 2.5, 2.5), C.WhiteHot, Enum.PartType.Cylinder)
	local line = fx("Drop", Vector3.new(0.7, 0.7, 1), C.DragonEye)
	line.Transparency = 0.45

	return { folder = folder, disc = disc, dot = dot, line = line }
end

local readout = text(gui, Theme.Font.Display, 22, C.UiText)
readout.AnchorPoint = Vector2.new(0.5, 1)
readout.Position = UDim2.new(0.5, 0, 1, -16)
readout.Size = UDim2.new(0, 560, 0, 28)
readout.Text = ""
readout.Visible = false

-- The jaw tips, read off the replicated dragon. The head segment spans wrist_roll -> tip and is
-- centred on its own pivot, so half its length forward along the local Z axis is the tip - the
-- same point the server calls arm.tip.
local function dragonTip(): Vector3?
	local dragon = workspace:FindFirstChild("Dragon")
	local head = dragon and dragon:FindFirstChild("Head")
	local core = head and head:FindFirstChild("Core")
	if not (core and core:IsA("BasePart")) then
		return nil
	end
	return (core.CFrame * CFrame.new(0, 0, core.Size.Z / 2)).Position
end

local function floorTopY(): number?
	local arenaModel = workspace:FindFirstChild("Arena")
	local floor = arenaModel and arenaModel:FindFirstChild("Floor")
	if not (floor and floor:IsA("BasePart")) then
		return nil
	end
	return floor.Position.Y + floor.Size.Y / 2
end

local function updateAim()
	if not aim then
		return
	end
	local tip = dragonTip()
	local floorY = floorTopY()
	if not tip or not floorY then
		aim.folder.Parent = nil
		readout.Text = ""
		return
	end
	aim.folder.Parent = workspace

	local ground = Vector3.new(tip.X, floorY + 0.08, tip.Z)
	local height = math.max(tip.Y - floorY, 0)

	-- Who is under the jaw. Measured flat, ignoring height, because that is exactly the question
	-- the overhead view cannot answer by itself.
	local radius = ArenaConfig.AIM_RETICLE_RADIUS
	local over: Player? = nil
	local nearest = math.huge
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and hum and hum.Health > 0 then
			local flat = (Vector3.new(root.Position.X, 0, root.Position.Z)
				- Vector3.new(ground.X, 0, ground.Z)).Magnitude
			if flat < nearest then
				nearest = flat
				if flat <= radius then
					over = p
				end
			end
		end
	end

	-- Warm throughout: this is the dragon's own aim, and rule 7 keeps the cool colours for the
	-- players. Red for "someone is under you", white-hot for "low enough to land a slam".
	local inRange = height <= slamStuds
	local colour = C.DragonEye
	if over then
		colour = C.UiDanger
	elseif inRange then
		colour = C.WhiteHot
	end

	aim.disc.Size = Vector3.new(0.4, radius * 2, radius * 2)
	aim.disc.CFrame = CFrame.new(ground) * CFrame.Angles(0, 0, math.pi / 2)
	aim.disc.Color = colour
	aim.disc.Transparency = over and 0.5 or 0.72

	aim.dot.CFrame = CFrame.new(ground + Vector3.new(0, 0.02, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	aim.dot.Color = colour

	-- The line's length is the height. That is the whole point of it: an overhead view destroys
	-- depth, and a bar that visibly shortens as the head comes down puts it back.
	-- Floored a little above the ground. At the bottom of a slam the tip IS the floor, and
	-- CFrame.lookAt with two coincident points produces a NaN CFrame - which would blow up the
	-- operator's view at the exact moment they most need it.
	local top = Vector3.new(tip.X, math.max(tip.Y, floorY + 0.3), tip.Z)
	aim.line.Size = Vector3.new(0.7, 0.7, math.max(height, 0.1))
	aim.line.CFrame = CFrame.lookAt(ground:Lerp(top, 0.5), top)
	aim.line.Color = colour

	local where
	if over then
		where = "OVER " .. string.upper(over.Name)
	elseif nearest < math.huge then
		where = string.format("NEAREST %d", math.floor(nearest))
	else
		where = "NO TARGET"
	end
	readout.Text = string.format("HEIGHT %d    %s%s", math.floor(height), where,
		inRange and "    STRIKE RANGE" or "")
	readout.TextColor3 = colour
end

local function setAimVisible(on: boolean)
	if on and ArenaConfig.AIM_SHOW then
		if not aim then
			aim = buildAim()
		end
		readout.Visible = true
	else
		if aim then
			aim.folder:Destroy()
			aim = nil
		end
		readout.Visible = false
	end
end

local function setAerial(on: boolean)
	if on == aerial then
		return
	end

	if on then
		local view = aerialCFrame()
		if not view then
			-- No floor yet means no `hello` yet. Say so rather than silently doing nothing, which
			-- looks identical to a broken keybind.
			hint.Text = "NO ARENA YET — START THE ROBOT PROCESS"
			task.delay(3, function()
				if not aerial then
					hint.Text = "V — AERIAL VIEW"
				end
			end)
			return
		end
		aerial = true
		aerialView = view
		hint.Text = "V — PLAYER VIEW"
		bar.Visible = false              -- the ability bar is the players' tool
		opText.Visible = true
		setAimVisible(true)

		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = view
		camera.FieldOfView = ArenaConfig.AERIAL_FOV

		for _, p in Players:GetPlayers() do
			if p.Character then
				mark(p.Character)
			end
		end
		for _, p in Players:GetPlayers() do
			table.insert(aerialConns, p.CharacterAdded:Connect(mark))
		end
		table.insert(aerialConns, Players.PlayerAdded:Connect(function(p)
			table.insert(aerialConns, p.CharacterAdded:Connect(mark))
		end))
		-- Re-asserted every frame: the engine takes the camera back whenever it decides the player
		-- needs a default one, and a view that silently drops to third person mid-demo is worse
		-- than one assignment a frame.
		table.insert(aerialConns, RunService.RenderStepped:Connect(function()
			if aerial and aerialView then
				if camera.CameraType ~= Enum.CameraType.Scriptable then
					camera.CameraType = Enum.CameraType.Scriptable
				end
				camera.CFrame = aerialView
				updateAim()
			end
		end))
	else
		aerial = false
		aerialView = nil
		hint.Text = "V — AERIAL VIEW"
		bar.Visible = true
		opText.Visible = false
		setAimVisible(false)
		for _, c in aerialConns do
			c:Disconnect()
		end
		table.clear(aerialConns)
		clearMarks()

		-- Hand the camera back. Without re-pointing CameraSubject the player is left staring at
		-- nothing when they toggle out after respawning.
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = 70          -- the engine default, so the player view is unchanged
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			camera.CameraSubject = hum
		end
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == AERIAL_KEY then
		setAerial(not aerial)
	end
end)

-- The server can still assign the view on join. Read rather than awaited: the attribute is set as
-- the player joins, which can be before this script runs, so checking the current value first is
-- what makes it work at all.
local OPERATOR_ATTRIBUTE = "ArenaOperator"

local function checkOperator()
	if player:GetAttribute(OPERATOR_ATTRIBUTE) and not aerial then
		-- The arena may not be built yet. Keep trying until it is, so an operator assigned on join
		-- still lands in the aerial view once the robot process connects.
		task.spawn(function()
			while player:GetAttribute(OPERATOR_ATTRIBUTE) and not aerial do
				setAerial(true)
				if aerial then
					break
				end
				task.wait(1)
			end
		end)
	end
end

player:GetAttributeChangedSignal(OPERATOR_ATTRIBUTE):Connect(checkOperator)
checkOperator()

-- The operator-facing debuff text follows the same payload the HUD does.
Remotes.Hud.OnClientEvent:Connect(function(payload)
	if not aerial then
		return
	end
	local lines = {}
	for _, e in (payload.effects or {}) do
		local msg = OPERATOR_FACING[e.name]
		if msg then
			table.insert(lines, msg)
		end
	end
	opText.Text = table.concat(lines, "   ")
end)
