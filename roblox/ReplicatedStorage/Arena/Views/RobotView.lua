--!strict
-- ReplicatedStorage.Arena.Views.RobotView
-- Dragon Arena for the robot role. The operator at the real arm IS the dragon, so this is the old
-- aerial operator view, made permanent: a fixed high camera over the whole arena, white outlines
-- on every player still alive in the round, operator-facing debuff text ("CONTROLS INVERTED")
-- across the top, the aiming aids, and the shared HUD (survivors, timer, effect chips, banners) -
-- no ability bar, which is the players' tool. There is no V key any more: the robot role has no
-- character (Core.Roles), and RoleClient already hands this view a Scriptable camera.
--
-- THE MAP COMES AND GOES. workspace.DragonArena exists only while a game runs, and the arcade can
-- make the arena the active game a moment before Start builds it, and removes it on Stop before
-- the view is switched away. So nothing here waits on it: every frame looks for it, and while it is
-- missing the screen shows a neutral "waiting for the arena" card and the camera is left where it
-- was. Nothing errors and nothing blocks enter().
--
-- Everything the operator sees that players must not (the outlines, the aiming aids) is built on
-- this client only - the Highlights under characters are local instances, and the aim parts live
-- under workspace.CurrentCamera - so none of it replicates.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Arena = ReplicatedStorage:WaitForChild("Arena")
local Theme = require(Arena:WaitForChild("Theme"))
local ArenaConfig = require(Arena:WaitForChild("ArenaConfig"))
local Client = Arena:WaitForChild("Client")
local Hud = require(Client:WaitForChild("Hud"))
local Look = require(Client:WaitForChild("Look"))

local C = Theme.Color
local player = Players.LocalPlayer

local MAP_NAME = "DragonArena"
local ALIVE = "ArenaAlive"
local RENDER_NAME = "ArenaRobotView"
local SWEEP_S = 0.5                -- how often the outlines are re-checked against every player

-- Debuffs that change what the operator's own hands are doing, shown large because they are the
-- reason the arm is not going where they pushed it.
local OPERATOR_FACING = {
	mirror = "CONTROLS INVERTED",
	fog = "CONTROLS LAGGING",
	molasses = "CONTROLS SLUGGISH",
	freeze = "ARM FROZEN",
	earthquake = "ARM SHAKING",
	butterfingers = "JAW JAMMED",
}

local RobotView = {}

-- One view session. Everything enter() makes is reachable from here, so exit() can take it apart.
local session = 0
local hud: any = nil
local opText: TextLabel? = nil
local readout: TextLabel? = nil
local waitGui: ScreenGui? = nil
local look: any = nil
local aim: any = nil
local connections: { RBXScriptConnection } = {}
local playerConns: { [Player]: { RBXScriptConnection } } = {}
local highlights: { [Player]: Highlight } = {}
local wiring: thread? = nil
local bound = false
local savedFov: number? = nil
local slamStuds = 5          -- replaced by the server's converted figure on the first payload
local streamedFor: Instance? = nil
local sweptAt = 0

-- ---------------------------------------------------------------------------------------------
-- Finding the map
-- ---------------------------------------------------------------------------------------------

local function findFloor(map: Instance?): BasePart?
	local arenaModel = map and map:FindFirstChild("Arena")
	local floor = arenaModel and arenaModel:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then
		return floor
	end
	return nil
end

-- Where to put the camera, from the floor's own size, so the framing survives a change to
-- ARENA_SCALE. Both fractions live in ArenaConfig - turn AERIAL_HEIGHT_FRAC down to come in closer.
local function aerialCFrame(floor: BasePart): CFrame
	local centre = floor.Position
	local span = math.max(floor.Size.X, floor.Size.Z)
	local height = span * ArenaConfig.AERIAL_HEIGHT_FRAC
	-- Pulled back toward the far edge and tilted, not straight down: a pure top-down view hides
	-- how high the head is, which is the one thing the operator needs to judge.
	local back = floor.Size.Z * ArenaConfig.AERIAL_BACK_FRAC
	return CFrame.lookAt(centre + Vector3.new(0, height, back), centre)
end

-- The jaw tips, read off the replicated dragon. The head segment spans wrist_roll -> tip and is
-- centred on its own pivot, so half its length forward along the local Z axis is the tip - the
-- same point the server calls arm.tip. Nil until the first arm frame has built the dragon.
local function dragonTip(map: Instance): Vector3?
	local dragon = map:FindFirstChild("Dragon")
	local head = dragon and dragon:FindFirstChild("Head")
	local core = head and head:FindFirstChild("Core")
	if not (core and core:IsA("BasePart")) then
		return nil
	end
	return (core.CFrame * CFrame.new(0, 0, core.Size.Z / 2)).Position
end

-- ---------------------------------------------------------------------------------------------
-- Outlines on the living
-- ---------------------------------------------------------------------------------------------

-- Dark avatars vanish against obsidian from overhead, and the operator has to see who they are
-- about to land a head on. Only players alive in the round are outlined - not the lobby, not the
-- dead - and only on this screen; the players never see this.
local function refreshMark(p: Player)
	local char = p.Character
	local want = p:GetAttribute(ALIVE) == true and char ~= nil
	local h = highlights[p]
	if h and (not want or h.Adornee ~= char or h.Parent == nil) then
		h:Destroy()
		highlights[p] = nil
		h = nil
	end
	if want and not h and char then
		local mark = Instance.new("Highlight")
		mark.Name = "ArenaOperatorMark"
		mark.OutlineColor = C.UiText
		mark.FillTransparency = 1
		mark.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		mark.Adornee = char
		mark.Parent = char
		highlights[p] = mark
	end
end

local function untrack(p: Player)
	local conns = playerConns[p]
	if conns then
		for _, c in conns do
			c:Disconnect()
		end
		playerConns[p] = nil
	end
	local h = highlights[p]
	if h then
		h:Destroy()
		highlights[p] = nil
	end
end

local function track(p: Player)
	if playerConns[p] then
		return
	end
	local function refresh()
		refreshMark(p)
	end
	playerConns[p] = {
		p:GetAttributeChangedSignal(ALIVE):Connect(refresh),
		p.CharacterAdded:Connect(refresh),
		-- Deferred: during CharacterRemoving the old model is still p.Character.
		p.CharacterRemoving:Connect(function()
			task.defer(refresh)
		end),
	}
	refreshMark(p)
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
-- dragon's own shadow, which rule 1 explicitly allows - and all of it is built here, under this
-- client's camera, so it does not replicate and no player ever sees it.
--
-- Three cues, because they answer three different questions:
--   the disc    - where on the floor am I? turns red when a player is under me
--   the line    - how high am I? its length IS the height, which is the cue overhead view destroys
--   the readout - the numbers, plus who I am over
-- ---------------------------------------------------------------------------------------------

local function buildAim()
	local folder = Instance.new("Folder")
	folder.Name = "OperatorAim"

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

local function hideAim()
	if aim then
		aim.folder.Parent = nil
	end
	if readout then
		readout.Text = ""
	end
end

local function updateAim(map: Instance, floor: BasePart)
	if not (aim and readout) then
		return
	end
	local tip = dragonTip(map)
	if not tip then
		hideAim()
		return
	end
	local camera = workspace.CurrentCamera
	if aim.folder.Parent ~= camera then
		aim.folder.Parent = camera
	end

	local floorY = floor.Position.Y + floor.Size.Y / 2
	local ground = Vector3.new(tip.X, floorY + 0.08, tip.Z)
	local height = math.max(tip.Y - floorY, 0)

	-- Who is under the jaw. Measured flat, ignoring height, because that is exactly the question
	-- the overhead view cannot answer by itself. Only players alive in the round count: someone
	-- standing in the lobby is never a target.
	local radius = ArenaConfig.AIM_RETICLE_RADIUS
	local over: Player? = nil
	local nearest = math.huge
	for _, p in Players:GetPlayers() do
		if p:GetAttribute(ALIVE) ~= true then
			continue
		end
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

-- ---------------------------------------------------------------------------------------------
-- The screens
-- ---------------------------------------------------------------------------------------------

local function buildScreens()
	hud = Hud.new("ArenaOperator")

	local op = Hud.text(hud.gui, Theme.Font.Display, 40, C.UiDanger)
	op.Name = "OperatorFacing"
	op.AnchorPoint = Vector2.new(0.5, 0)
	op.Position = UDim2.new(0.5, 0, 0, 110)
	op.Size = UDim2.new(1, -40, 0, 50)
	op.Text = ""
	opText = op

	local who = Hud.text(hud.gui, Theme.Font.Label, 14, C.UiText)
	who.Name = "Role"
	who.AnchorPoint = Vector2.new(1, 0)
	who.Position = UDim2.new(1, -16, 0, 16)
	who.Size = UDim2.new(0, 220, 0, 18)
	who.TextXAlignment = Enum.TextXAlignment.Right
	who.TextTransparency = 0.35
	who.Text = "YOU ARE THE DRAGON"

	-- The aiming readout takes the bottom centre; the spectate line, which never applies to the
	-- dragon, sits under it and stays empty.
	local r = Hud.text(hud.gui, Theme.Font.Display, 22, C.UiText)
	r.Name = "AimReadout"
	r.AnchorPoint = Vector2.new(0.5, 1)
	r.Position = UDim2.new(0.5, 0, 1, -16)
	r.Size = UDim2.new(0, 560, 0, 28)
	r.Text = ""
	r.Visible = ArenaConfig.AIM_SHOW
	readout = r

	-- Shown while there is no arena: between the game going active and Start building the map,
	-- and between Stop removing it and the view switching back to the lobby.
	local screen = Instance.new("ScreenGui")
	screen.Name = "ArenaOperatorWait"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.Enabled = true

	local dim = Instance.new("Frame")
	dim.BackgroundColor3 = C.UiInk
	dim.BackgroundTransparency = 0.35
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Parent = screen

	local title = Hud.text(screen, Theme.Font.Display, 64, C.UiText)
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.42)
	title.Size = UDim2.new(1, -40, 0, 72)
	title.Text = "DRAGON ARENA"

	local sub = Hud.text(screen, Theme.Font.Label, 24, C.UiText)
	sub.AnchorPoint = Vector2.new(0.5, 0.5)
	sub.Position = UDim2.new(0.5, 0, 0.42, 64)
	sub.Size = UDim2.new(1, -40, 0, 30)
	sub.TextTransparency = 0.2
	sub.Text = "Waiting for the arena..."

	screen.Parent = player:WaitForChild("PlayerGui")
	waitGui = screen

	if ArenaConfig.AIM_SHOW then
		aim = buildAim()
	end
end

-- Stream the arena in around this client once per map. The robot has no character, so streaming
-- would otherwise centre on its replication focus, which may be nowhere near the arena - and a
-- character that never streams in can be neither outlined nor aimed at. The map itself is
-- Persistent; this is for the players on it.
local function streamAround(map: Instance, floor: BasePart)
	if streamedFor == map or not workspace.StreamingEnabled then
		return
	end
	streamedFor = map
	local centre = map:GetAttribute("Center")
	local at: Vector3 = if typeof(centre) == "Vector3" then centre else floor.Position
	task.spawn(function()
		pcall(function()
			player:RequestStreamAroundAsync(at)
		end)
	end)
end

local function render()
	if not (hud and waitGui) then
		return
	end
	local camera = workspace.CurrentCamera
	local map = workspace:FindFirstChild(MAP_NAME)
	local floor = findFloor(map)

	if not (map and floor) then
		hud.gui.Enabled = false
		waitGui.Enabled = true
		hideAim()
		if savedFov then
			camera.FieldOfView = savedFov
			savedFov = nil
		end
		Hud.step(hud)
		return
	end

	hud.gui.Enabled = true
	waitGui.Enabled = false
	streamAround(map, floor)

	-- Re-asserted every frame: the engine takes the camera back whenever it decides the client
	-- needs a default one, and a view that silently drops to third person mid-demo is worse than
	-- one assignment a frame.
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	camera.CFrame = aerialCFrame(floor)
	if savedFov == nil then
		savedFov = camera.FieldOfView
	end
	camera.FieldOfView = ArenaConfig.AERIAL_FOV

	if os.clock() - sweptAt >= SWEEP_S then
		sweptAt = os.clock()
		for _, p in Players:GetPlayers() do
			refreshMark(p)
		end
	end

	updateAim(map, floor)
	Hud.step(hud)
end

local function wire(r: any)
	table.insert(connections, r.Hud.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" or not hud then
			return
		end
		Hud.apply(hud, payload)
		slamStuds = tonumber(payload.slamStuds) or slamStuds
		local lines = {}
		for _, e in (payload.effects or {}) do
			local msg = OPERATOR_FACING[e.name]
			if msg then
				table.insert(lines, msg)
			end
		end
		if opText then
			opText.Text = table.concat(lines, "   ")
		end
	end))
	table.insert(connections, r.Banner.OnClientEvent:Connect(function(info)
		if typeof(info) == "table" and hud then
			Hud.banner(hud, info)
		end
	end))
	-- No Shake: the dragon's own slam does not shake the dragon's camera, and the server sends it
	-- only to players near the impact anyway.
end

-- ---------------------------------------------------------------------------------------------
-- enter / exit
-- ---------------------------------------------------------------------------------------------

function RobotView.enter(_ctx: any)
	RobotView.exit()
	session += 1
	local mine = session

	buildScreens()
	look = Look.start(true)

	for _, p in Players:GetPlayers() do
		track(p)
	end
	table.insert(connections, Players.PlayerAdded:Connect(track))
	table.insert(connections, Players.PlayerRemoving:Connect(untrack))

	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value, render)
	bound = true

	wiring = Hud.awaitRemotes(function()
		return session == mine
	end, function(r)
		wiring = nil
		if session == mine then
			wire(r)
		end
	end)
end

-- Safe to call twice, and before any enter.
function RobotView.exit()
	session += 1
	if wiring then
		if coroutine.status(wiring) == "suspended" then
			task.cancel(wiring)
		end
		wiring = nil
	end
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	for p in playerConns do
		untrack(p)
	end
	for p, h in highlights do
		h:Destroy()
		highlights[p] = nil
	end
	if bound then
		RunService:UnbindFromRenderStep(RENDER_NAME)
		bound = false
	end
	Look.stop(look)
	look = nil
	if aim then
		aim.folder:Destroy()
		aim = nil
	end
	if hud then
		Hud.destroy(hud)
		hud = nil
	end
	if waitGui then
		waitGui:Destroy()
		waitGui = nil
	end
	opText = nil
	readout = nil
	if savedFov then
		local camera = workspace.CurrentCamera
		if camera then
			camera.FieldOfView = savedFov
		end
		savedFov = nil
	end
	slamStuds = 5
	streamedFor = nil
	sweptAt = 0
end

return RobotView
