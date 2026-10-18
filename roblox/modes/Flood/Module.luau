-- Studio location: ServerStorage.Modes.Flood.Module (ModuleScript); theme maps are in ServerStorage.Modes.Flood.Themes
--[[
	Rising Flood, as an arcade mode (see the mode contract in arcade-plan.md).

	Water fills the chamber, the robot operator stacks real blocks on the tower
	spot, and each block becomes a cube + ledge in a spiral tower the players climb.
	Players still above the water when the timer runs out win.

	Tower height input (the grid game):
	  - Each round picks a path of squares on the 3x4 grid sheet (length from the Difficulty
	    attribute: Easy 6, Medium 9, Hard 12). The operator moves ONE real block along it; each
	    time the block reaches the next square of the path, the tower grows by one.
	  - Robot: StateStore blocks[i].cell ("B3"), or blocks[i].x/.y in cm from tag 0's inner corner
	  - Studio mock: B = block reached the next square, N = step back, C = clear (FloodClient)

	Themes: the Flood folder's Theme attribute picks a map from Themes ("Water", "Sewer",
	or "Random"). Every theme map has the same anchor parts (Floor, Water, WaterSurface,
	Tower, ArenaSpawn). A theme may add a ThemeServer ModuleScript with optional hooks:
	apply(session), onHeartbeat(session, dt), styleBlock(model, k, session), revert(session).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local Flood = ReplicatedStorage:WaitForChild("Flood")
local Config = require(Flood:WaitForChild("FloodConfig"))
local debugRemote = Flood:WaitForChild("FloodDebug")
local fxRemote = Flood:WaitForChild("FloodFx")
local StateStore = require(ServerStorage:WaitForChild("Shared"):WaitForChild("StateStore"))

local THEMES = script.Parent:WaitForChild("Themes")

local function pickTheme()
	local want = script.Parent:GetAttribute("Theme") or "Water"
	if want == "Random" then
		local names = {}
		for _, t in THEMES:GetChildren() do
			if t:IsA("Model") then
				table.insert(names, t.Name)
			end
		end
		want = names[math.random(#names)]
	end
	local map = THEMES:FindFirstChild(want)
	if not (map and map:IsA("Model")) then
		map = THEMES.Water
	end
	return map
end

local W = Config.BLOCK_WIDTH
local L = Config.LEDGE_LENGTH
local THICK = Config.LEDGE_THICKNESS

-- A snake through the 3x4 grid: only straight moves to a neighbouring square. Starts in a random
-- corner, runs along the rows or the columns, and stops after `length` squares.
local function makePath(length)
	local rows, cols = Config.GRID.rows, Config.GRID.cols
	local nr = #rows
	local byRows = math.random() < 0.5
	local flipR, flipC = math.random() < 0.5, math.random() < 0.5
	local outer = if byRows then nr else cols
	local inner = if byRows then cols else nr
	local cells = {}
	for o = 0, outer - 1 do
		for i = 0, inner - 1 do
			local along = if o % 2 == 0 then i else inner - 1 - i
			local r = if byRows then o else along
			local c = if byRows then along else o
			if flipR then
				r = nr - 1 - r
			end
			if flipC then
				c = cols - 1 - c
			end
			table.insert(cells, rows[r + 1] .. tostring(c + 1))
		end
	end
	local path = {}
	for k = 1, math.min(length, #cells) do
		path[k] = cells[k]
	end
	return path
end

-- Which grid square the block is in. Python can send blocks[i].cell ("B3") directly, or just
-- blocks[i].x / .y in cm measured from the sheet's top-left corner (tag 0's inner corner).
local function cellOf(state)
	local g = Config.GRID
	for _, b in state.blocks or {} do
		if type(b) == "table" and b.visible ~= false and not b.held then
			if type(b.cell) == "string" then
				return string.upper(b.cell)
			end
			local x, y = tonumber(b.x), tonumber(b.y)
			if x and y then
				local col = math.floor((x * 10 - g.originX) / g.cell) + 1
				local row = math.floor((y * 10 - g.originY) / g.cell) + 1
				if col >= 1 and col <= g.cols and row >= 1 and row <= #g.rows then
					return g.rows[row] .. tostring(col)
				end
			end
		end
	end
	return nil
end

-- Ledge k sticks out of cube face (k - 1) % 4, so the ledges spiral upward.
local FACE_DIRS = { Vector3.xAxis, Vector3.zAxis, -Vector3.xAxis, -Vector3.zAxis }

-- The next round's difficulty is rolled while players are still in the lobby, so the bay can show it
-- before anyone walks in. Re-rolled after every round.
local nextDiff

local function describe(name)
	local d = Config.DIFFICULTY[name]
	return string.format("%s  ·  %d SQUARES  ·  %ds", name:upper(), d.cells, d.time)
end

local function rollDifficulty()
	local want = script.Parent:GetAttribute("Difficulty") or Config.DEFAULT_DIFFICULTY
	if want == "Random" then
		local names = { "Easy", "Medium", "Hard" }
		local pick
		repeat -- don't repeat last round's difficulty, so it feels random
			pick = names[math.random(#names)]
		until pick ~= nextDiff
		want = pick
	end
	if not Config.DIFFICULTY[want] then
		want = Config.DEFAULT_DIFFICULTY
	end
	nextDiff = want
	Flood:SetAttribute("NextDifficulty", want)
	return want
end

local Mode = {}
Mode.DisplayName = "Rising Flood"
Mode.Tip = describe(rollDifficulty())

-- show the next difficulty on every bay that runs Flood (ArcadeManager sets it once at startup)
local function showNextDifficulty()
	Mode.Tip = describe(nextDiff)
	local bays = workspace:FindFirstChild("Workshop") and workspace.Workshop:FindFirstChild("Bays")
	if not bays then
		return
	end
	for _, bay in bays:GetChildren() do
		local label = bay:GetAttribute("Mode") == "Flood" and bay:FindFirstChild("TipLabel")
		local tip = label and label:FindFirstChild("Tip", true)
		if tip then
			tip.Text = Mode.Tip
		end
	end
end
Mode.WinsToUnlock = 0
Mode.Finished = Instance.new("BindableEvent")

local s -- the running session, nil when Flood isn't running

------------------------------------------------------------------ helpers

local function rootOf(player)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return hrp, hum
	end
end

local function inArena(hrp)
	local d = hrp.Position - s.center
	return math.abs(d.X) < s.half and math.abs(d.Z) < s.half and d.Y > -5
end

local function setWaterlogged(player, on)
	player:SetAttribute("Flooded", on)
	local _, hum = rootOf(player)
	if hum then
		hum.WalkSpeed = if on then 6 else game.StarterPlayer.CharacterWalkSpeed
		hum.JumpHeight = if on then 2 else game.StarterPlayer.CharacterJumpHeight
	end
end

local function setState(state, message)
	s.state = state
	Flood:SetAttribute("Message", message or "") -- before State, so clients read it on the State change
	Flood:SetAttribute("State", state)
end

------------------------------------------------------------------ tower

local function slotGeometry(k)
	local top = s.floorY + k * s.step
	local dir = FACE_DIRS[(k - 1) % 4 + 1]
	local cubeCF = CFrame.new(s.center.X, top - s.step / 2, s.center.Z)
	local ledgeCF = CFrame.new(Vector3.new(s.center.X, top - THICK / 2, s.center.Z) + dir * (W / 2 + L / 2))
	local ledgeSize = if dir.X ~= 0 then Vector3.new(L, THICK, W) else Vector3.new(W, THICK, L)
	return top, cubeCF, ledgeCF, ledgeSize
end

local function newPart(name, size, cf, color, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.Parent = parent
	return p
end

local function buildSlot(k, name)
	local _, cubeCF, ledgeCF, ledgeSize = slotGeometry(k)
	local color = Config.BLOCK_COLORS[(k - 1) % #Config.BLOCK_COLORS + 1]
	local model = Instance.new("Model")
	model.Name = name
	newPart("Cube", Vector3.new(W, s.step, W), cubeCF, color, model)
	newPart("Ledge", ledgeSize, ledgeCF, color:Lerp(Color3.new(0, 0, 0), 0.25), model)
	return model
end

local function updateGhost()
	if s.ghost then
		s.ghost:Destroy()
		s.ghost = nil
	end
	if s.height >= Config.MAX_STEPS then
		return
	end
	s.ghost = buildSlot(s.height + 1, "NextSlotGhost")
	for _, p in s.ghost:GetChildren() do
		p.Material = Enum.Material.ForceField
		p.Transparency = 0.3
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
	end
	s.ghost.Parent = s.tower
end

-- Characters standing where a new block lands get lifted onto it.
local function liftOverlappingCharacters(model, top)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local chars = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(chars, p.Character)
		end
	end
	params.FilterDescendantsInstances = chars
	local lifted = {}
	for _, part in model:GetChildren() do
		for _, hit in workspace:GetPartBoundsInBox(part.CFrame, part.Size, params) do
			local char = hit:FindFirstAncestorOfClass("Model")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hum and hrp and not lifted[char] then
				lifted[char] = true
				local standY = top + hum.HipHeight + hrp.Size.Y / 2 + 0.2
				char:PivotTo(char:GetPivot() + Vector3.new(0, standY - hrp.Position.Y, 0))
			end
		end
	end
end

local function beam(top)
	local b = Instance.new("Part")
	b.Name = "Beam"
	b.Shape = Enum.PartType.Cylinder
	b.Size = Vector3.new(60, W * 0.9, W * 0.9)
	b.CFrame = CFrame.new(s.center.X, top + 30, s.center.Z) * CFrame.Angles(0, 0, math.rad(90))
	b.Material = Enum.Material.Neon
	b.Color = Color3.fromRGB(150, 230, 255)
	b.Transparency = 0.4
	b.Anchored = true
	b.CanCollide = false
	b.CanQuery = false
	b.CanTouch = false
	b.CastShadow = false
	b.Parent = s.tower
	TweenService:Create(b, TweenInfo.new(0.6), { Transparency = 1, Size = Vector3.new(60, 0.2, 0.2) }):Play()
	Debris:AddItem(b, 0.7)
end

local function ping(parent, speed)
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxasset://sounds/electronicpingshort.wav"
	sound.Volume = 0.8
	sound.PlaybackSpeed = speed
	sound.RollOffMaxDistance = 200
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 3)
end

local function addStep(k)
	local session = s
	local top = slotGeometry(k)
	local model = buildSlot(k, "Step" .. k)
	if s.hooks and s.hooks.styleBlock then
		s.hooks.styleBlock(model, k, s)
	end
	local finals = {}
	for _, p in model:GetChildren() do
		finals[p] = p.CFrame
		p.CanCollide = false
		p.Transparency = 0.6
		p.CFrame += Vector3.new(0, 30, 0)
	end
	model.Parent = s.tower
	s.steps[k] = model
	beam(top)
	ping(model.Cube, 1 + k * 0.08)

	local info = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local last
	for p, cf in finals do
		last = TweenService:Create(p, info, { CFrame = cf, Transparency = 0 })
		last:Play()
	end
	last.Completed:Wait()
	if s ~= session or s.steps[k] ~= model then
		return -- removed while dropping in, or the game stopped
	end
	for p in finals do
		p.CanCollide = true
	end
	liftOverlappingCharacters(model, top)
end

local function removeStep(k)
	local model = s.steps[k]
	s.steps[k] = nil
	if not model then
		return
	end
	for _, p in model:GetChildren() do
		p.CanCollide = false
		p.Anchored = false
		p.AssemblyLinearVelocity = Vector3.new(math.random(-15, 15), 10, math.random(-15, 15))
		p.AssemblyAngularVelocity = Vector3.new(math.random(-4, 4), math.random(-4, 4), math.random(-4, 4))
	end
	ping(model.Cube, 0.5)
	Debris:AddItem(model, 3)
end

local function applyHeight(n)
	n = math.clamp(math.floor(n), 0, Config.MAX_STEPS)
	if n == s.height then
		return
	end
	local old = s.height
	s.height = n
	Flood:SetAttribute("TowerHeight", n)
	if n > old then
		for k = old + 1, n do
			task.spawn(addStep, k)
		end
	else
		for k = old, n + 1, -1 do
			removeStep(k)
		end
		if s.state == "Running" then
			s.surgeUntil = os.clock() + Config.SURGE_DURATION
			fxRemote:FireAllClients("surge", old - n)
		end
	end
	updateGhost()
end

local function setProgress(n)
	n = math.clamp(n, 0, #s.path)
	s.progress = n
	Flood:SetAttribute("Progress", n)
	applyHeight(n)
end

-- The block counts only when it lands on the NEXT square of the path, so wandering or
-- going back never adds blocks.
local function onRobotState()
	local cell = cellOf(StateStore.get())
	local nextCell = s.path[s.progress + 1]
	if cell and nextCell and cell == nextCell then
		setProgress(s.progress + 1)
	end
end

------------------------------------------------------------------ water

local function setWater(level)
	s.waterLevel = level
	Flood:SetAttribute("WaterLevel", level)
	level = math.max(level, 0)
	local water, surface = s.water, s.surface
	if level <= 0.05 then
		water.Transparency = 1
		surface.Transparency = 1
		water.Size = Vector3.new(s.waterXZ, 0.05, s.waterXZ)
		water.CFrame = CFrame.new(s.center)
	else
		water.Transparency = s.liquidT
		surface.Transparency = s.surfaceT
		water.Size = Vector3.new(s.waterXZ, level, s.waterXZ)
		water.CFrame = CFrame.new(s.center + Vector3.new(0, level / 2, 0))
	end
	surface.CFrame = CFrame.new(s.center + Vector3.new(0, level + 0.1, 0))
end

------------------------------------------------------------------ round

-- escaped = the path was finished, so the round ends early and survivors get out
local function finish(won, escaped)
	if s.done then
		return
	end
	s.done = true
	setState(if won then "Won" else "Lost", if escaped then "Escaped" else "")
	fxRemote:FireAllClients(if escaped then "escaped" elseif won then "won" else "lost")

	local results = {}
	for p in s.players do
		table.insert(results, { player = p, won = won and not s.flooded[p] })
	end

	local session = s
	table.insert(s.threads, task.delay(Config.RESULT_TIME, function()
		if s == session then
			Mode.Finished:Fire(results)
		end
	end))
end

local function onHeartbeat(dt)
	if s.state ~= "Running" then
		return
	end

	local elapsed = os.clock() - s.roundStart
	local timeLeft = math.max(0, s.roundTime - elapsed)
	Flood:SetAttribute("TimeLeft", timeLeft)
	if elapsed > Config.GRACE_TIME then
		local mult = if os.clock() < s.surgeUntil then Config.SURGE_MULTIPLIER else 1
		setWater(math.min(s.waterEnd, s.waterLevel + s.riseRate * mult * dt))
	end

	local waterY = s.floorY + s.waterLevel
	local alive = 0
	for p in s.players do
		if not s.flooded[p] then
			local hrp = p.Parent and rootOf(p)
			if not hrp or not inArena(hrp) or hrp.Position.Y < waterY then
				s.flooded[p] = true
				if p.Parent then
					setWaterlogged(p, true)
					fxRemote:FireAllClients("flooded", p.DisplayName)
				end
			else
				alive += 1
			end
		end
	end

	if s.hooks and s.hooks.onHeartbeat then
		s.hooks.onHeartbeat(s, dt)
	end

	if alive == 0 then
		finish(false)
	elseif s.progress >= #s.path then
		finish(true, true) -- path done: everyone still above the liquid escapes right away
	elseif timeLeft <= 0 then
		finish(true)
	end
end

------------------------------------------------------------------ contract

function Mode.Start(players)
	if s then
		Mode.Stop()
	end

	local map = pickTheme()
	local hooksModule = map:FindFirstChild("ThemeServer")
	local hooks = if hooksModule then require(hooksModule) else nil
	local arena = map:Clone()
	arena.Name = "FloodArena"
	local hooksCopy = arena:FindFirstChild("ThemeServer")
	if hooksCopy then
		hooksCopy:Destroy()
	end
	local settings = arena:FindFirstChild("Settings")

	-- difficulty (rolled in the lobby) -> path length and round time; tower step and final water
	-- level follow from it
	local diffName = nextDiff
	local diff = Config.DIFFICULTY[diffName]
	local path = makePath(diff.cells)
	local target = #path
	local step = Config.stepFor(target)
	local waterEnd = Config.waterEndFor(target, step)

	local floor = arena:WaitForChild("Floor")
	local floorY = floor.Position.Y + floor.Size.Y / 2
	s = {
		arena = arena,
		tower = arena:WaitForChild("Tower"),
		water = arena:WaitForChild("Water"),
		surface = arena:WaitForChild("WaterSurface"),
		floorY = floorY,
		center = Vector3.new(floor.Position.X, floorY, floor.Position.Z),
		half = floor.Size.X / 2,
		waterXZ = arena.Water.Size.X,
		players = {},
		flooded = {},
		steps = {},
		conns = {},
		threads = {},
		height = 0,
		waterLevel = 0,
		surgeUntil = 0,
		roundStart = 0,
		state = "Countdown",
		done = false,
		theme = map.Name,
		hooks = hooks,
		settings = settings,
		liquidT = settings and settings:GetAttribute("LiquidTransparency") or 0.35,
		surfaceT = settings and settings:GetAttribute("SurfaceTransparency") or 0.55,
		path = path,
		progress = 0,
		target = target,
		step = step,
		waterEnd = waterEnd,
		roundTime = diff.time,
		riseRate = (waterEnd - Config.WATER_START) / (diff.time - Config.GRACE_TIME) * Config.RISE_SPEED,
	}
	Flood:SetAttribute("ActiveTheme", map.Name)
	Flood:SetAttribute("Difficulty", diffName)
	Flood:SetAttribute("Path", table.concat(path, ","))
	Flood:SetAttribute("Progress", 0)
	Flood:SetAttribute("TargetSteps", target)
	Flood:SetAttribute("StepHeight", step)
	Flood:SetAttribute("RoundTime", diff.time)
	Flood:SetAttribute("WaterEnd", waterEnd)
	arena.Parent = workspace

	Flood:SetAttribute("TowerHeight", 0)
	Flood:SetAttribute("TimeLeft", diff.time)
	Flood:SetAttribute("Active", true)
	setState("Countdown")
	setWater(Config.WATER_START)
	updateGhost()

	-- move players right next to the tower spot, on the diagonals between the four ledge directions
	-- (the ledges stick straight out of the cube faces, so the diagonals stay clear), facing it
	local SLOTS = { Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1), Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1) }
	for i, p in players do
		s.players[p] = true
		p:SetAttribute("Flooded", false)
		if p.Character then
			local ring = (i - 1) // #SLOTS -- 5th+ players stand a little further out
			local offset = SLOTS[(i - 1) % #SLOTS + 1] * (W / 2 + 4 + ring * 3)
			local pos = s.center + offset + Vector3.new(0, 4, 0)
			p.Character:PivotTo(CFrame.lookAt(pos, Vector3.new(s.center.X, pos.Y, s.center.Z)))
		end
	end

	table.insert(s.conns, RunService.Heartbeat:Connect(onHeartbeat))
	table.insert(s.conns, StateStore.Updated.Event:Connect(onRobotState))
	table.insert(s.conns, debugRemote.OnServerEvent:Connect(function(_, action)
		if not RunService:IsStudio() then
			return
		end
		if action == "add" then
			setProgress(s.progress + 1) -- mock: the block reached the next square
		elseif action == "remove" then
			setProgress(s.progress - 1)
		elseif action == "clear" then
			setProgress(0)
		end
	end))

	if hooks and hooks.apply then
		hooks.apply(s)
	end

	local session = s
	table.insert(s.threads, task.spawn(function()
		for i = Config.COUNTDOWN, 1, -1 do
			Flood:SetAttribute("Countdown", i)
			task.wait(1)
		end
		if s ~= session then
			return
		end
		s.roundStart = os.clock()
		setState("Running")
	end))
end

function Mode.Stop()
	if not s then
		return
	end
	local session = s
	s = nil
	for _, c in session.conns do
		c:Disconnect()
	end
	for _, t in session.threads do
		pcall(task.cancel, t)
	end
	for p in session.players do
		if p.Parent then
			p:SetAttribute("Flooded", false)
			local _, hum = rootOf(p)
			if hum then
				hum.WalkSpeed = game.StarterPlayer.CharacterWalkSpeed
				hum.JumpHeight = game.StarterPlayer.CharacterJumpHeight
			end
		end
	end
	if session.hooks and session.hooks.revert then
		local ok, err = pcall(session.hooks.revert, session)
		if not ok then
			warn("[Flood] theme revert failed: " .. tostring(err))
		end
	end
	session.arena:Destroy()
	Flood:SetAttribute("ActiveTheme", "")
	Flood:SetAttribute("Active", false)
	Flood:SetAttribute("State", "Idle")
	Flood:SetAttribute("Message", "")
	Flood:SetAttribute("WaterLevel", 0)
	Flood:SetAttribute("TowerHeight", 0)
	Flood:SetAttribute("Progress", 0)
	Flood:SetAttribute("Path", "")
	rollDifficulty()
	showNextDifficulty()
end

return Mode
