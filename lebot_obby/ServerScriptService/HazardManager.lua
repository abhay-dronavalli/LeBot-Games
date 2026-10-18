-- HazardManager -- one obstacle per bay (4x3). Each obstacle owns its whole bay, is lethal
-- while unsolved, and resolves when the required blocks land in its solveCells.
--
-- Design rule throughout: the blocks that SOLVE an obstacle are also the player's safe footing.
-- Nothing may kill the player while they're standing on the thing that solved it.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local BayData = require(ReplicatedStorage:WaitForChild("BayData"))
local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))

local CELL = Config.CellSize

local function bayZStart(i)
	return (i - 1) * Config.BayPitch
end

local function cellCenter(i, col, row)
	return Vector3.new(col * CELL + CELL / 2, 0, bayZStart(i) + row * CELL + CELL / 2)
end

local function bayCenter(i)
	return Vector3.new(Config.BayWidth / 2, 0, bayZStart(i) + Config.BayDepth / 2)
end

local function newPart(name, size, pos, color, material, parent, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.Size = size
	p.CFrame = CFrame.new(pos)
	p.Color = color or Color3.fromRGB(150, 150, 150)
	p.Material = material or Enum.Material.SmoothPlastic
	if props then
		for k, v in pairs(props) do
			p[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function addLabel(parent, text, pos, color)
	local anchor = newPart("Label", Vector3.new(0.2, 0.2, 0.2), pos, nil, nil, parent,
		{Transparency = 1, CanQuery = false})
	local b = Instance.new("BillboardGui")
	b.Size = UDim2.new(0, 190, 0, 40)
	b.AlwaysOnTop = true
	b.Parent = anchor
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 1, 0)
	l.BackgroundTransparency = 0.35
	l.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
	l.TextColor3 = color or Color3.fromRGB(255, 255, 255)
	l.Font = Enum.Font.SourceSansBold
	l.TextScaled = true
	l.Text = text
	l.Parent = b
	return l
end

-- Debug ghost mode (Q) makes a character untouchable by every obstacle.
local function isGhost(character)
	return character ~= nil and character:GetAttribute("Ghost") == true
end

local function characterFrom(hit)
	local model = hit and hit:FindFirstAncestorOfClass("Model")
	if not model then
		return nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum and Players:GetPlayerFromCharacter(model) and not isGhost(model) then
		return model, hum
	end
	return nil
end

-- Per-part lethality, for obstacles made of many independently-switchable pieces (the laser
-- grid). The part carries its own "Live" attribute instead of reading the bay's solved flag.
local function makeLethalPart(part)
	part:SetAttribute("Live", true)
	part.CanTouch = true
	part.Touched:Connect(function(hit)
		if part:GetAttribute("Live") ~= true then
			return
		end
		local _, hum = characterFrom(hit)
		if hum and hum.Health > 0 then
			hum.Health = 0
		end
	end)
end

-- Lethal touch that respects the solved flag, so solved obstacles stop killing.
local function makeLethal(part, state)
	part.CanTouch = true
	part.Touched:Connect(function(hit)
		if state.solved then
			return
		end
		local _, hum = characterFrom(hit)
		if hum and hum.Health > 0 then
			hum.Health = 0
		end
	end)
end

----------------------------------------------------------------
-- Obstacle builders. Each returns a `state` table with .solved and :setSolved(bool)
----------------------------------------------------------------
local BUILDERS = {}

-- SAW WALL: the bay seals and a wall of chainsaws creeps in from the entrance. Two levers,
-- mounted too high to reach from the floor, are the way out -- so here the crates are a LADDER
-- to the answer rather than the answer itself. Lever A kills the blades and arms Lever B;
-- Lever B halts the wall and drops the exit gate. The advancing wall is the clock, which makes
-- Config.SawWallSeconds the one knob for this bay's difficulty.
--
-- Why a crate can stall the wall, and why that isn't a free win: a crate can never be
-- destroyed, because the real cube is still sitting on the operator's table and the game has
-- to mirror it. So contact is resolved by whether there is anything to cut with --
--   blades live -> they chew through, wall slows to Config.SawWallGrindFactor
--   blades dead -> nothing cuts, wall jams solid
-- That gives the spare cube a real job (buy time before Lever A) and makes the Lever B stack
-- double as a shield afterwards, so the player is never killed standing on the block that
-- saved them.
BUILDERS.Saw = function(i, folder, info, state)
	local z0 = bayZStart(i)
	local zEnd = z0 + Config.BayDepth
	local midX = Config.BayWidth / 2

	local WALL_START = z0 + 2
	local WALL_END = zEnd - 2.5
	local TICK = 0.05
	-- Advance off measured elapsed time, not tick count: task.wait(0.05) actually sleeps a bit
	-- longer, which made a nominal 30s traverse take about 34s. The wall is this bay's clock,
	-- so SawWallSeconds has to mean real seconds.
	local studsPerSecond = (WALL_END - WALL_START) / Config.SawWallSeconds
	local lastTick = os.clock()

	-- paint the sweep lane, so the operator can see where a brake crate actually intercepts
	newPart("SweepLane", Vector3.new(Config.BayWidth - 1, 0.08, Config.BayDepth - 1),
		Vector3.new(midX, 0.06, z0 + Config.BayDepth / 2), Color3.fromRGB(120, 92, 22),
		Enum.Material.SmoothPlastic, folder, {Transparency = 0.6, CanQuery = false})

	----------------------------------------------------------------
	-- gates
	----------------------------------------------------------------
	local GATE_H = 14
	local entryGate = newPart("EntryGate", Vector3.new(Config.BayWidth, GATE_H, 1),
		Vector3.new(midX, -GATE_H / 2, z0), Color3.fromRGB(72, 68, 62),
		Enum.Material.DiamondPlate, folder, {CanCollide = true})
	local exitGate = newPart("ExitGate", Vector3.new(Config.BayWidth, GATE_H, 1),
		Vector3.new(midX, GATE_H / 2, zEnd), Color3.fromRGB(72, 68, 62),
		Enum.Material.DiamondPlate, folder, {CanCollide = true})

	local function slideGate(gate, up)
		TweenService:Create(gate, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{CFrame = CFrame.new(gate.Position.X, up and GATE_H / 2 or -GATE_H / 2, gate.Position.Z)}):Play()
	end

	----------------------------------------------------------------
	-- the wall
	----------------------------------------------------------------
	local frame = newPart("WallFrame", Vector3.new(Config.BayWidth, 7.4, 1.2),
		Vector3.new(midX, 3.8, WALL_START), Color3.fromRGB(58, 54, 50),
		Enum.Material.DiamondPlate, folder, {CanCollide = true})

	local blades = {}
	for col = 0, Config.BayCols - 1 do
		local bx = col * CELL + CELL / 2
		-- a Cylinder's flat faces point along X, so this is a vertical disc facing sideways
		-- and it spins about its own axis rather than tumbling
		local blade = newPart("WallBlade" .. col, Vector3.new(0.4, 5.6, 5.6),
			Vector3.new(bx, 3.4, WALL_START), Color3.fromRGB(208, 210, 216),
			Enum.Material.Metal, folder, {Shape = Enum.PartType.Cylinder})
		makeLethalPart(blade)
		table.insert(blades, {part = blade, x = bx})
	end

	local sparks = newPart("Sparks", Vector3.new(Config.BayWidth - 2, 0.5, 0.5),
		Vector3.new(midX, 1.2, WALL_START), Color3.fromRGB(255, 200, 70),
		Enum.Material.Neon, folder, {Transparency = 1, CanQuery = false})

	local wallZ, spin, bladesLive = WALL_START, 0, true

	local function placeWall(z)
		frame.CFrame = CFrame.new(midX, 3.8, z)
		for _, b in ipairs(blades) do
			b.part.CFrame = CFrame.new(b.x, 3.4, z) * CFrame.Angles(spin, 0, 0)
		end
		sparks.CFrame = CFrame.new(midX, 1.2, z + 1.2)
	end

	local function setBladesLive(live)
		bladesLive = live
		for _, b in ipairs(blades) do
			b.part:SetAttribute("Live", live)
			b.part.Color = live and Color3.fromRGB(208, 210, 216) or Color3.fromRGB(96, 98, 104)
		end
	end

	-- nearest crate the wall is about to meet, or nil
	local function crateInPath(z)
		if not Config.SawWallBrakeEnabled then
			return nil
		end
		for _, c in ipairs(folder.Parent:GetChildren()) do
			if c.Name == "Crate" then
				local b = c:FindFirstChild("Base")
				if b and b.Position.Z > z and b.Position.Z - z < 3.1 then
					return b
				end
			end
		end
		return nil
	end

	----------------------------------------------------------------
	-- levers. Colour code is deliberate: green means "this is your target right now" and
	-- nothing else is ever green, so a thrown lever goes cold blue instead of staying green.
	----------------------------------------------------------------
	local DORMANT, ARMED, THROWN = 0, 1, 2
	local HANDLE_LEN = 2.4

	-- A lever only responds if the player is standing on a crate tall enough for it. Gating on
	-- the support, rather than mounting the lever out of jump range, keeps the cube requirement
	-- exact -- Lever A needs any crate, Lever B needs a stacked pair. Without this check a
	-- default jump from the floor reaches roughly 12.8 studs of head height and clears both.
	local function supportHeight(character)
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if not hrp then
			return 0
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {character}
		local hit = Workspace:Raycast(hrp.Position, Vector3.new(0, -9, 0), params)
		if not hit or (hit.Instance.Name ~= "Base" and hit.Instance.Name ~= "Topper") then
			return 0
		end
		return hit.Instance.Position.Y + hit.Instance.Size.Y / 2
	end

	local function buildLever(spec)
		local inward = (spec.side == "left") and 1 or -1
		local x = (spec.side == "left") and 1.75 or Config.BayWidth - 1.75
		local z = cellCenter(i, spec.cell[1], spec.cell[2]).Z
		local y = spec.height

		local lv = {id = spec.id, phase = DORMANT, minStand = spec.minStand or 0}
		-- the housing juts into the bay so it abuts the crate in that column; mounted flush
		-- with the wall it sits a couple of studs short of the crate's edge
		lv.mount = newPart("Lever" .. spec.id .. "Mount", Vector3.new(3.5, 3.4, 3.4),
			Vector3.new(x, y, z), Color3.fromRGB(40, 40, 46), Enum.Material.DiamondPlate, folder)
		lv.beacon = newPart("Lever" .. spec.id .. "Beacon", Vector3.new(0.34, 5.2, 0.34),
			Vector3.new(x, y + 1.4, z + 2.4), Color3.fromRGB(34, 34, 38),
			Enum.Material.Neon, folder, {CanQuery = false})

		lv.pivot = Vector3.new(x + inward * 1.4, y - 1.0, z)
		lv.handle = newPart("Lever" .. spec.id .. "Handle", Vector3.new(0.45, HANDLE_LEN, 0.45),
			lv.pivot, Color3.fromRGB(190, 58, 52), Enum.Material.Metal, folder)

		function lv.setAngle(deg)
			lv.handle.CFrame = CFrame.new(lv.pivot)
				* CFrame.Angles(math.rad(inward * deg), 0, 0)
				* CFrame.new(0, HANDLE_LEN / 2, 0)
		end
		lv.setAngle(0)

		lv.light = Instance.new("PointLight")
		lv.light.Range = 18
		lv.light.Brightness = 0
		lv.light.Color = Color3.fromRGB(90, 255, 130)
		lv.light.Parent = lv.mount

		lv.label = addLabel(folder, "LEVER " .. spec.id,
			Vector3.new(x + inward * 1.8, y + 3.6, z), Color3.fromRGB(130, 130, 140))

		-- characterFrom already drops ghosts and non-players, so spectating can't cheat it
		lv.mount.CanTouch = true
		lv.mount.Touched:Connect(function(hit)
			local ch, hum = characterFrom(hit)
			if not (ch and hum and hum.Health > 0) or lv.phase ~= ARMED then
				return
			end
			-- too low to count. No message here: a lever mounted for a stacked pair is
			-- physically out of touch from a single crate, so this branch rarely even runs.
			-- The proximity hint in the run loop is what actually tells the player why.
			if supportHeight(ch) < lv.minStand then
				return
			end
			if lv.onThrow then
				lv.onThrow()
			end
		end)
		return lv
	end

	local levers = {}
	for _, spec in ipairs(info.levers or {}) do
		levers[spec.id] = buildLever(spec)
	end
	local leverA, leverB = levers.A, levers.B

	local function setPhase(lv, phase)
		if not lv then
			return
		end
		lv.phase = phase
		if phase == DORMANT then
			lv.mount.Color = Color3.fromRGB(40, 40, 46)
			lv.beacon.Color = Color3.fromRGB(34, 34, 38)
			lv.light.Brightness = 0
			lv.label.Text = "LEVER " .. lv.id .. "  -  LOCKED"
			lv.label.TextColor3 = Color3.fromRGB(125, 125, 135)
			lv.setAngle(0)
		elseif phase == ARMED then
			lv.mount.Color = Color3.fromRGB(46, 72, 50)
			lv.label.Text = "LEVER " .. lv.id .. "  -  LIVE"
			lv.label.TextColor3 = Color3.fromRGB(120, 255, 150)
		else
			lv.light.Color = Color3.fromRGB(110, 180, 255)
			lv.light.Brightness = 1.3
			lv.mount.Color = Color3.fromRGB(48, 60, 76)
			lv.beacon.Color = Color3.fromRGB(90, 170, 255)
			lv.label.Text = "LEVER " .. lv.id .. "  -  THROWN"
			lv.label.TextColor3 = Color3.fromRGB(130, 200, 255)
			task.spawn(function()
				for d = 0, 70, 7 do
					lv.setAngle(d)
					task.wait(0.02)
				end
			end)
		end
	end

	----------------------------------------------------------------
	-- run / reset. The obstacle stays dormant until someone is actually inside, which also
	-- gives the reset for free: when the bay empties unsolved, everything goes back.
	----------------------------------------------------------------
	local running = false

	local function playersInBay()
		local found = {}
		for _, pl in ipairs(Players:GetPlayers()) do
			local ch = pl.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if hrp and hum and hum.Health > 0 and not isGhost(ch) then
				local p = hrp.Position
				if p.Z > z0 and p.Z < zEnd and p.X > -2 and p.X < Config.BayWidth + 2 and p.Y > -8 then
					table.insert(found, {character = ch, humanoid = hum, position = p})
				end
			end
		end
		return found
	end

	local function armRun()
		running = true
		wallZ = WALL_START
		spin = 0
		lastTick = os.clock()
		setBladesLive(true)
		placeWall(wallZ)
		slideGate(entryGate, true)
		setPhase(leverA, ARMED)
		setPhase(leverB, DORMANT)
	end

	local function resetRun()
		running = false
		wallZ = WALL_START
		setBladesLive(true)
		placeWall(wallZ)
		sparks.Transparency = 1
		slideGate(entryGate, false)
		slideGate(exitGate, true)
		setPhase(leverA, DORMANT)
		setPhase(leverB, DORMANT)
	end

	if leverA then
		function leverA.onThrow()
			setPhase(leverA, THROWN)
			setBladesLive(false)
			setPhase(leverB, ARMED)
			print("[HazardManager] saw wall: Lever A thrown, blades dead")
		end
	end

	if leverB then
		function leverB.onThrow()
			setPhase(leverB, THROWN)
			running = false
			sparks.Transparency = 1
			slideGate(exitGate, false)
			print("[HazardManager] saw wall: Lever B thrown, wall halted")
			if state.setSolved then
				state.setSolved(true)
			end
		end
	end

	placeWall(WALL_START)
	setPhase(leverA, DORMANT)
	setPhase(leverB, DORMANT)

	task.spawn(function()
		while folder.Parent do
			local occupants = playersInBay()

			if state.solved then
				-- cleared for good; leave the exit open and the wall where it stopped
			elseif not running then
				if #occupants > 0 then
					armRun()
				end
			elseif #occupants == 0 then
				resetRun()
			else
				local now = os.clock()
				-- clamp, so a hitch or a resumed session can't teleport the wall forward
				local dt = math.min(now - lastTick, 0.25)
				lastTick = now

				if bladesLive then
					spin += math.rad(520) * dt
				end

				local blocker = crateInPath(wallZ)
				local advance = studsPerSecond * dt
				if blocker then
					advance = bladesLive and advance * Config.SawWallGrindFactor or 0
				end
				-- sparks only while something is actually being chewed
				sparks.Transparency = (blocker and bladesLive) and (0.25 + math.random() * 0.5) or 1

				wallZ = math.min(wallZ + advance, WALL_END)
				placeWall(wallZ)

				for _, o in ipairs(occupants) do
					-- behind the front face (tunnelled through), or pinned at the exit
					if o.position.Z < wallZ - 0.8 or wallZ >= WALL_END - 0.05 then
						o.humanoid.Health = 0
					end
				end
			end

			-- pulse whichever lever is the live target, and tell a player who is standing
			-- near it on too short a stack why nothing is happening. Lever B is deliberately
			-- mounted high enough that a single crate cannot even make contact, so without
			-- this hint the obstacle just reads as broken.
			for _, lv in pairs(levers) do
				if lv.phase == ARMED then
					local k = 0.5 + 0.5 * math.sin(os.clock() * 4)
					lv.light.Brightness = 1.2 + k * 2.2
					lv.beacon.Color = Color3.fromRGB(40 + 90 * k, 150 + 105 * k, 60 + 70 * k)

					local tooLow = false
					for _, o in ipairs(occupants) do
						if (o.position - lv.mount.Position).Magnitude < 8
							and supportHeight(o.character) < lv.minStand then
							tooLow = true
						end
					end
					if tooLow then
						lv.label.Text = "LEVER " .. lv.id .. "  -  STACK HIGHER"
						lv.label.TextColor3 = Color3.fromRGB(255, 150, 90)
					else
						lv.label.Text = "LEVER " .. lv.id .. "  -  LIVE"
						lv.label.TextColor3 = Color3.fromRGB(120, 255, 150)
					end
				end
			end

			task.wait(TICK)
		end
	end)

	function state.onSolved() end
end

-- VOID: the floor is gone over `coverRows`. The placed blocks ARE the bridge across.
BUILDERS.Void = function(i, folder, info, state)
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	local floor = bay and bay:FindFirstChild("Floor")
	local rows = info.coverRows or {0, 1, 2}

	if floor then
		if #rows >= 3 then
			floor.Transparency = 1
			floor.CanCollide = false
			floor.CanTouch = false
		else
			-- shrink the floor back so only the untouched rows keep solid ground
			local keptStart = (math.max(table.unpack(rows)) + 1) * CELL
			local keptDepth = Config.BayDepth - keptStart
			floor.Size = Vector3.new(Config.BayWidth, 1, keptDepth)
			floor.CFrame = CFrame.new(Config.BayWidth / 2, -0.5,
				bayZStart(i) + keptStart + keptDepth / 2)
		end
	end

	-- edge warning lips so the drop reads as intentional
	for _, row in ipairs(rows) do
		local z = bayZStart(i) + row * CELL
		newPart("VoidEdge", Vector3.new(Config.BayWidth, 0.4, 0.8),
			Vector3.new(Config.BayWidth / 2, 0.2, z), Color3.fromRGB(220, 40, 40),
			Enum.Material.Neon, folder)
	end

	-- catch plane well below: falling in is a death, not an endless drop
	local catcher = newPart("VoidCatcher", Vector3.new(Config.BayWidth + 12, 2, Config.BayDepth),
		Vector3.new(Config.BayWidth / 2, -24, bayCenter(i).Z), Color3.fromRGB(0, 0, 0),
		Enum.Material.SmoothPlastic, folder, {Transparency = 1})
	catcher.CanTouch = true
	catcher.Touched:Connect(function(hit)
		local _, hum = characterFrom(hit)
		if hum and hum.Health > 0 then
			hum.Health = 0
		end
	end)

	function state.onSolved() end
end

-- LASER: red, semi-transparent beam across row 1. A block stops the beam, so everything past
-- the block is safe to walk through.
-- LASER GRID: a heist-movie lattice of red beams filling the whole bay volume. Because the
-- beams span the bay there's no walkable gap to carve, so the yellow mirror crate cuts power
-- to the whole grid instead of interrupting a single shot.
BUILDERS.Laser = function(i, folder, info, state)
	local z0 = bayZStart(i)
	-- Pure saturated red, kept fairly opaque. Semi-transparent neon picks up whatever is behind
	-- it, and the warm warehouse lighting was turning these salmon/orange.
	local RED = Color3.fromRGB(255, 0, 0)
	local beams, emitters, movers = {}, {}, {}
	local beamCount = 0

	local function beamBetween(a, b, thickness)
		local delta = b - a
		local mid = a + delta / 2
		local p = newPart("LaserBeam", Vector3.new(thickness, thickness, delta.Magnitude), mid,
			RED, Enum.Material.Neon, folder, {Transparency = 0.15})
		p.CFrame = CFrame.lookAt(mid, b)
		makeLethalPart(p)
		table.insert(beams, p)

		-- a few beams carry their own red light so the bay is lit red rather than orange
		beamCount += 1
		if beamCount % 5 == 0 then
			local l = Instance.new("PointLight")
			l.Color = Color3.fromRGB(255, 20, 20)
			l.Range = 14
			l.Brightness = 2.2
			l.Parent = p
		end
		return p
	end

	local function emitter(pos)
		local e = newPart("Emitter", Vector3.new(1.1, 1.1, 1.1), pos,
			Color3.fromRGB(38, 38, 44), Enum.Material.Metal, folder)
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 50, 50)
		l.Range = 9
		l.Brightness = 1.6
		l.Parent = e
		table.insert(emitters, e)
		return e
	end

	local heights = {1.6, 4.0, 6.4, 8.8}
	local zLines = {3, 8, 12, 16, 21}

	-- beams running across the bay, wall to wall
	for _, zo in ipairs(zLines) do
		local z = z0 + zo
		for hi, y in ipairs(heights) do
			local b = beamBetween(Vector3.new(0, y, z), Vector3.new(Config.BayWidth, y, z), 0.22)
			-- every other beam slowly sweeps up and down like a scanner
			if (hi + zo) % 2 == 0 then
				table.insert(movers, {part = b, baseY = y, x = Config.BayWidth / 2, z = z,
					phase = (zo + hi) * 0.7})
			end
		end
		emitter(Vector3.new(-0.9, heights[1], z))
		emitter(Vector3.new(Config.BayWidth + 0.9, heights[#heights], z))
	end

	-- beams running the length of the bay
	for col = 0, 3 do
		local x = col * CELL + CELL / 2
		for _, y in ipairs({2.8, 5.2, 7.6}) do
			beamBetween(Vector3.new(x, y, z0), Vector3.new(x, y, z0 + Config.BayDepth), 0.2)
		end
	end

	-- corner-to-corner diagonals to break up the regular lattice
	beamBetween(Vector3.new(0, 1.2, z0), Vector3.new(Config.BayWidth, 9.2, z0 + Config.BayDepth), 0.2)
	beamBetween(Vector3.new(Config.BayWidth, 1.2, z0), Vector3.new(0, 9.2, z0 + Config.BayDepth), 0.2)
	beamBetween(Vector3.new(0, 9.2, z0), Vector3.new(Config.BayWidth, 1.2, z0 + Config.BayDepth), 0.2)

	-- live flicker + scanner sweep
	task.spawn(function()
		while folder.Parent do
			if not state.solved then
				local t = os.clock()
				local flicker = 0.16 + math.sin(t * 5) * 0.07
				for _, b in ipairs(beams) do
					if b:GetAttribute("Live") == true then
						b.Transparency = flicker
					end
				end
				for _, m in ipairs(movers) do
					if m.part.Parent then
						local y = m.baseY + math.sin(t * 0.9 + m.phase) * 1.1
						m.part.CFrame = CFrame.lookAt(
							Vector3.new(m.x, y, m.z),
							Vector3.new(Config.BayWidth, y, m.z))
					end
				end
			end
			task.wait(0.04)
		end
	end)

	function state.onSolved()
		-- staggered power-down, so the grid dies in a sweep rather than all at once
		task.spawn(function()
			for idx, b in ipairs(beams) do
				b:SetAttribute("Live", false)
				TweenService:Create(b, TweenInfo.new(0.3), {Transparency = 1}):Play()
				if idx % 3 == 0 then
					task.wait(0.04)
				end
			end
			for _, e in ipairs(emitters) do
				e.Color = Color3.fromRGB(70, 70, 76)
				for _, l in ipairs(e:GetChildren()) do
					if l:IsA("PointLight") then
						l.Enabled = false
					end
				end
			end
		end)
	end
end

-- LAVA: rises on a timer and forces the player to keep moving. Blocks stand proud of the
-- maximum level, so a placed path stays dry. Solving freezes the rise (cryo) but the lava
-- itself stays lethal -- the blocks are the way across.
BUILDERS.Lava = function(i, folder, info, state)
	local maxY = 3.2 -- crates are 4 tall, so their tops stay dry
	local riseFor = (info.level == 2) and 12 or 20

	-- pool only covers `coverRows`, so the bay stays crossable on a 2-cube budget
	local rows = info.coverRows or {0, 1, 2}
	local poolStart = math.min(table.unpack(rows)) * CELL
	local poolDepth = (#rows) * CELL
	local centre = Vector3.new(Config.BayWidth / 2, 0,
		bayZStart(i) + poolStart + poolDepth / 2)

	local lava = newPart("Lava", Vector3.new(Config.BayWidth - 0.5, 0.6, poolDepth - 0.5),
		Vector3.new(centre.X, 0.2, centre.Z), Color3.fromRGB(255, 94, 12),
		Enum.Material.Neon, folder)
	makeLethal(lava, state)
	local poolWidth = Config.BayWidth - 0.5
	local poolSpan = poolDepth - 0.5

	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 130, 40)
	-- kept short-range on purpose: at Range 30 this flooded the neighbouring laser bay with
	-- orange and made the red beams read salmon
	glow.Range = 15
	glow.Brightness = 2
	glow.Parent = lava

	task.spawn(function()
		local t = 0
		while folder.Parent do
			if not state.solved then
				t = math.min(t + 0.1, riseFor)
				local h = (t / riseFor) * maxY
				lava.Size = Vector3.new(poolWidth, 0.6 + h, poolSpan)
				lava.CFrame = CFrame.new(centre.X, (0.6 + h) / 2 - 0.1, centre.Z)
			end
			task.wait(0.1)
		end
	end)

	function state.onSolved()
		lava.Color = Color3.fromRGB(255, 150, 60)
	end
end

-- CRUSHER ROOF: the whole ceiling of the bay descends. A stacked pair props it; the roof
-- halts ON the stack, leaving headroom for the player to walk under.
BUILDERS.CrusherRoof = function(i, folder, info, state)
	local centre = bayCenter(i)
	local startY = 15
	local propY = 8.2  -- rests on a stacked pair (4 + ~3.5)
	local crushY = 1.6 -- unsolved: comes all the way down

	local roof = newPart("CrusherRoof", Vector3.new(Config.BayWidth, 1.6, Config.BayDepth),
		Vector3.new(centre.X, startY, centre.Z), Color3.fromRGB(86, 60, 38),
		Enum.Material.Metal, folder, {CanCollide = true})

	-- spikes underneath so the threat reads instantly
	for col = 0, 3 do
		for row = 0, 2 do
			local cc = cellCenter(i, col, row)
			local spike = newPart("Spike", Vector3.new(0.8, 1.4, 0.8),
				Vector3.new(cc.X, startY - 1.4, cc.Z), Color3.fromRGB(60, 62, 68),
				Enum.Material.Metal, folder)
			spike:SetAttribute("Offset", -1.4)
		end
	end

	local spikes = {}
	for _, p in ipairs(folder:GetChildren()) do
		if p.Name == "Spike" then
			table.insert(spikes, p)
		end
	end

	local currentY = startY
	task.spawn(function()
		while folder.Parent do
			local goal = state.solved and propY or crushY
			currentY = currentY + (goal - currentY) * 0.015
			roof.CFrame = CFrame.new(centre.X, currentY, centre.Z)
			for _, s in ipairs(spikes) do
				s.CFrame = CFrame.new(s.Position.X, currentY - 1.5, s.Position.Z)
			end

			-- crush anything caught under a descending (unsolved) roof
			if not state.solved and currentY < 6 then
				for _, pl in ipairs(Players:GetPlayers()) do
					local ch = pl.Character
					local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
					local hum = ch and ch:FindFirstChildOfClass("Humanoid")
					if hrp and hum and hum.Health > 0 and not isGhost(ch) then
						local p = hrp.Position
						if math.abs(p.Z - centre.Z) < Config.BayDepth / 2
							and p.X > 0 and p.X < Config.BayWidth
							and p.Y < currentY then
							hum.Health = 0
						end
					end
				end
			end
			task.wait(0.05)
		end
	end)

	function state.onSolved() end
end

-- MOBS: Minecraft-style zombies spawn from two wall openings and chase the player. Blocks
-- seal the openings, which stops the spawns; the lane itself stays open to walk through.
local ZOMBIE_SKIN = Color3.fromRGB(106, 140, 79)
local ZOMBIE_SHIRT = Color3.fromRGB(58, 106, 118)
local ZOMBIE_PANTS = Color3.fromRGB(58, 62, 104)

local function buildZombie(spawnPos, parent)
	local m = Instance.new("Model")
	m.Name = "Zombie"

	local function limb(name, size, color)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = m
		return p
	end

	local root = limb("HumanoidRootPart", Vector3.new(2, 2, 1), ZOMBIE_SHIRT)
	root.Transparency = 1
	root.CFrame = CFrame.new(spawnPos)

	local torso = limb("Torso", Vector3.new(2, 2, 1), ZOMBIE_SHIRT)
	local head = limb("Head", Vector3.new(1.6, 1.6, 1.6), ZOMBIE_SKIN)
	local la = limb("Left Arm", Vector3.new(1, 2, 1), ZOMBIE_SKIN)
	local ra = limb("Right Arm", Vector3.new(1, 2, 1), ZOMBIE_SKIN)
	local ll = limb("Left Leg", Vector3.new(1, 2, 1), ZOMBIE_PANTS)
	local rl = limb("Right Leg", Vector3.new(1, 2, 1), ZOMBIE_PANTS)

	-- dark sunken eyes
	for _, sx in ipairs({-0.38, 0.38}) do
		local eye = Instance.new("Part")
		eye.Size = Vector3.new(0.34, 0.26, 0.1)
		eye.Color = Color3.fromRGB(18, 28, 20)
		eye.Material = Enum.Material.SmoothPlastic
		eye.Name = "Eye"
		eye.Parent = m
		local w = Instance.new("Weld")
		w.Part0 = head
		w.Part1 = eye
		w.C0 = CFrame.new(sx, 0.12, -0.82)
		w.Parent = eye
	end

	local function joint(p1, c0, name)
		local j = Instance.new("Motor6D")
		j.Name = name
		j.Part0 = torso
		j.Part1 = p1
		j.C0 = c0
		j.Parent = torso
		return j
	end

	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.Parent = root

	joint(head, CFrame.new(0, 1.8, 0), "Neck")
	local leftArm = joint(la, CFrame.new(-1.5, 0.4, 0), "LeftShoulder")
	local rightArm = joint(ra, CFrame.new(1.5, 0.4, 0), "RightShoulder")
	local leftLeg = joint(ll, CFrame.new(-0.5, -1.6, 0), "LeftHip")
	local rightLeg = joint(rl, CFrame.new(0.5, -1.6, 0), "RightHip")

	local hum = Instance.new("Humanoid")
	hum.MaxHealth = 60
	hum.Health = 60
	hum.WalkSpeed = 7
	hum.Parent = m

	m.PrimaryPart = root
	m.Parent = parent

	-- arms out front + shambling leg swing
	local baseLA, baseRA = leftArm.C0, rightArm.C0
	local baseLL, baseRL = leftLeg.C0, rightLeg.C0
	leftArm.C0 = baseLA * CFrame.Angles(math.rad(-80), 0, 0)
	rightArm.C0 = baseRA * CFrame.Angles(math.rad(-80), 0, 0)

	task.spawn(function()
		while m.Parent and hum.Health > 0 do
			local s = math.sin(os.clock() * 5) * 0.5
			leftLeg.C0 = baseLL * CFrame.Angles(s, 0, 0)
			rightLeg.C0 = baseRL * CFrame.Angles(-s, 0, 0)
			leftArm.C0 = baseLA * CFrame.Angles(math.rad(-80) + s * 0.25, 0, 0)
			rightArm.C0 = baseRA * CFrame.Angles(math.rad(-80) - s * 0.25, 0, 0)
			task.wait(0.06)
		end
	end)

	return m, hum, root
end

BUILDERS.Mobs = function(i, folder, info, state)
	local z = cellCenter(i, 0, 1).Z
	local mobs = {}

	-- two spawner openings in the side walls
	local spawners = {}
	for _, sx in ipairs({-0.4, Config.BayWidth + 0.4}) do
		local hole = newPart("Spawner", Vector3.new(1.2, 6, CELL - 1),
			Vector3.new(sx, 3, z), Color3.fromRGB(18, 14, 24),
			Enum.Material.Slate, folder)
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(120, 60, 200)
		l.Range = 10
		l.Brightness = 1.5
		l.Parent = hole
		table.insert(spawners, hole)
	end

	task.spawn(function()
		while folder.Parent do
			if not state.solved and #mobs < 4 then
				local from = spawners[math.random(1, #spawners)]
				local pos = from.Position + Vector3.new(from.Position.X < 0 and 3 or -3, 0, 0)
				local m, hum, root = buildZombie(Vector3.new(pos.X, 4, pos.Z), folder)
				table.insert(mobs, m)

				-- chase + attack
				task.spawn(function()
					while m.Parent and hum.Health > 0 do
						local best, bestD = nil, 1e9
						for _, pl in ipairs(Players:GetPlayers()) do
							local ch = pl.Character
							local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
							-- ghosts are invisible to mobs
							if hrp and not isGhost(ch) then
								local d = (hrp.Position - root.Position).Magnitude
								if d < bestD then best, bestD = ch, d end
							end
						end
						if best and bestD < 60 then
							hum:MoveTo(best.HumanoidRootPart.Position)
							if bestD < 4 then
								local ph = best:FindFirstChildOfClass("Humanoid")
								if ph and ph.Health > 0 then
									ph:TakeDamage(12)
									task.wait(1)
								end
							end
						end
						task.wait(0.3)
					end
				end)
			end
			task.wait(3)
		end
	end)

	function state.onSolved()
		for _, s in ipairs(spawners) do
			s.Color = Color3.fromRGB(70, 70, 78)
			for _, d in ipairs(s:GetChildren()) do
				if d:IsA("PointLight") then d.Enabled = false end
			end
		end
		for _, m in ipairs(mobs) do
			if m.Parent then m:Destroy() end
		end
		table.clear(mobs)
	end
end

-- ARROW TURRETS: wall dispensers fire volleys across the bay. Arrows physically die against
-- any crate, so a placed block is real hard cover you can stand behind; filling both solve
-- cells also shuts the turrets down.
BUILDERS.ArrowTurrets = function(i, folder, info, state)
	local z0 = bayZStart(i)
	local turrets = {}

	for _, side in ipairs({{x = -0.9, dir = 1}, {x = Config.BayWidth + 0.9, dir = -1}}) do
		for _, row in ipairs({0, 2}) do
			local z = z0 + row * CELL + CELL / 2
			for _, y in ipairs({2.2, 4.8}) do
				local t = newPart("Dispenser", Vector3.new(1.7, 1.7, 1.7),
					Vector3.new(side.x, y, z), Color3.fromRGB(62, 60, 56),
					Enum.Material.Slate, folder)
				local eye = Instance.new("PointLight")
				eye.Color = Color3.fromRGB(255, 150, 60)
				eye.Range = 7
				eye.Brightness = 1.2
				eye.Parent = t
				table.insert(turrets, {part = t, dir = side.dir, y = y, z = z})
			end
		end
	end

	local function crateBlocks(pos)
		local bay = folder.Parent
		for _, c in ipairs(bay:GetChildren()) do
			if c.Name == "Crate" then
				local b = c:FindFirstChild("Base")
				if b and math.abs(b.Position.X - pos.X) < 2.6
					and math.abs(b.Position.Z - pos.Z) < 2.6
					and pos.Y < b.Position.Y + 2.5 then
					return true
				end
			end
		end
		return false
	end

	task.spawn(function()
		while folder.Parent do
			if not state.solved then
				for _, t in ipairs(turrets) do
					local arrow = newPart("Arrow", Vector3.new(2.4, 0.26, 0.26),
						Vector3.new(t.part.Position.X + t.dir * 1.6, t.y, t.z),
						Color3.fromRGB(205, 190, 165), Enum.Material.Wood, folder)
					makeLethalPart(arrow)

					task.spawn(function()
						local travelled = 0
						while arrow.Parent and travelled < Config.BayWidth + 4 do
							arrow.CFrame = arrow.CFrame + Vector3.new(t.dir * 1.5, 0, 0)
							travelled += 1.5
							if crateBlocks(arrow.Position) then
								break -- absorbed by cover
							end
							task.wait(0.03)
						end
						if arrow.Parent then
							arrow:Destroy()
						end
					end)
				end
			end
			task.wait(2.4)
		end
	end)

	function state.onSolved()
		for _, t in ipairs(turrets) do
			t.part.Color = Color3.fromRGB(90, 88, 84)
			for _, l in ipairs(t.part:GetChildren()) do
				if l:IsA("PointLight") then
					l.Enabled = false
				end
			end
		end
		for _, a in ipairs(folder:GetChildren()) do
			if a.Name == "Arrow" then
				a:Destroy()
			end
		end
	end
end

-- DARK ZONE: lights out, with pits you cannot see until something lights them. The only
-- obstacle solved by what the block EMITS rather than what it blocks.
BUILDERS.DarkZone = function(i, folder, info, state)
	local centre = bayCenter(i)

	-- kill the overhead lights above this bay
	local dimmed = {}
	local rails = Workspace.Warehouse:FindFirstChild("SkyRails")
	if rails then
		for _, t in ipairs(rails:GetChildren()) do
			if string.match(t.Name, "^Truss")
				and math.abs(t.Position.Z - centre.Z) < Config.BayDepth / 2 + 8 then
				for _, l in ipairs(t:GetChildren()) do
					if l:IsA("SpotLight") then
						l.Enabled = false
						table.insert(dimmed, l)
					end
				end
			end
		end
	end

	local murk = newPart("Darkness", Vector3.new(Config.BayWidth + 12, 22, Config.BayDepth),
		Vector3.new(centre.X, 11, centre.Z), Color3.fromRGB(0, 0, 3),
		Enum.Material.SmoothPlastic, folder, {Transparency = 0.5, CanQuery = false})

	-- pits hidden in the dark
	local pits = {}
	for _, cell in ipairs({{0, 0}, {3, 0}, {2, 1}, {1, 2}, {3, 2}}) do
		local c = cellCenter(i, cell[1], cell[2])
		local pit = newPart("HiddenPit", Vector3.new(CELL - 1.5, 0.4, CELL - 1.5),
			Vector3.new(c.X, 0.15, c.Z), Color3.fromRGB(30, 0, 0),
			Enum.Material.Neon, folder, {Transparency = 0.92})
		makeLethal(pit, state)
		table.insert(pits, pit)
	end

	function state.onSolved()
		TweenService:Create(murk, TweenInfo.new(0.9), {Transparency = 1}):Play()
		for _, l in ipairs(dimmed) do
			l.Enabled = true
		end
		for _, p in ipairs(pits) do
			p.Transparency = 0.25
			p.Color = Color3.fromRGB(255, 70, 70)
		end
		-- the teal crates themselves become the light source
		for _, c in ipairs(folder.Parent:GetChildren()) do
			if c.Name == "Crate" then
				local b = c:FindFirstChild("Base")
				if b and not b:FindFirstChildOfClass("PointLight") then
					local l = Instance.new("PointLight")
					l.Color = Color3.fromRGB(130, 255, 240)
					l.Range = 30
					l.Brightness = 3.5
					l.Parent = b
				end
			end
		end
	end
end

-- ICE: frictionless floor. You slide through a pinch point with lethal drops either side;
-- the blocks are guard rails that cover them.
BUILDERS.Ice = function(i, folder, info, state)
	local centre = bayCenter(i)
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	local floor = bay and bay:FindFirstChild("Floor")
	if floor then
		floor.Material = Enum.Material.Ice
		floor.Color = Color3.fromRGB(165, 225, 255)
		-- low friction, heavily weighted so it wins over the character's own properties
		floor.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.02, 0.1, 50, 1)
	end

	-- frosty sheen over the lane
	newPart("Frost", Vector3.new(Config.BayWidth - 1, 0.12, Config.BayDepth - 1),
		Vector3.new(centre.X, 0.08, centre.Z), Color3.fromRGB(210, 245, 255),
		Enum.Material.Glass, folder, {Transparency = 0.55, CanQuery = false})

	-- the pinch point: lethal drops at the outer cells of the middle row
	for _, col in ipairs({0, 3}) do
		local c = cellCenter(i, col, 1)
		local drop = newPart("ColdDrop", Vector3.new(CELL - 0.5, 0.5, CELL - 0.5),
			Vector3.new(c.X, 0.25, c.Z), Color3.fromRGB(16, 48, 96),
			Enum.Material.Neon, folder, {Transparency = 0.25})
		makeLethal(drop, state)
		newPart("DropEdge", Vector3.new(CELL - 0.5, 0.5, 0.5),
			Vector3.new(c.X, 0.35, c.Z - CELL / 2), Color3.fromRGB(120, 220, 255),
			Enum.Material.Neon, folder)
	end

	function state.onSolved()
		-- rails are up: the drops are covered, so take the shine off them
		for _, p in ipairs(folder:GetChildren()) do
			if p.Name == "ColdDrop" then
				p.Color = Color3.fromRGB(70, 110, 150)
				p.Transparency = 0.6
			end
		end
	end
end

----------------------------------------------------------------
-- Build every bay
----------------------------------------------------------------
local states = {}

local function buildBay(i)
	local info = BayData[i]
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	if not info or not bay then
		return
	end

	local folder = bay:FindFirstChild("Obstacle")
	if folder then folder:Destroy() end
	folder = Instance.new("Folder")
	folder.Name = "Obstacle"
	folder.Parent = bay

	local builder = BUILDERS[info.obstacle]
	if not builder then
		warn("[HazardManager] no builder for obstacle " .. tostring(info.obstacle))
		return
	end

	local state = {solved = false, info = info, folder = folder}

	-- The one place a bay becomes solved or unsolved, so the two routes in -- cells filled
	-- (checkSolved) and an obstacle deciding for itself (the saw wall's levers) -- share the
	-- same presentation and the same edge-only onSolved call.
	function state.setSolved(solved)
		if solved == state.solved then
			return
		end
		state.solved = solved
		if solved then
			print(string.format("[HazardManager] %s SOLVED", state.info.obstacle))
			if state.label then
				state.label.Text = state.info.obstacle:upper() .. "  -  CLEARED"
				state.label.TextColor3 = Color3.fromRGB(120, 240, 140)
			end
			if state.onSolved then
				state.onSolved()
			end
		elseif state.label then
			state.label.Text = state.banner
			state.label.TextColor3 = Color3.fromRGB(255, 180, 90)
		end
	end

	builder(i, folder, info, state)

	CollectionService:AddTag(folder, "Obstacle")
	folder:SetAttribute("Obstacle", info.obstacle)
	folder:SetAttribute("Color", info.color)
	folder:SetAttribute("Level", info.level)

	local c = bayCenter(i)
	state.banner = (info.solveMode == "switches")
		and string.format("%s  -  THROW BOTH LEVERS", info.obstacle:upper())
		or string.format("%s  -  %s x%d", info.obstacle:upper(), info.color:upper(), info.level)
	state.label = addLabel(folder, state.banner,
		Vector3.new(c.X, 11, c.Z), Color3.fromRGB(255, 180, 90))

	states[bay] = state
	return state
end

for i = 1, Config.NumBays do
	buildBay(i)
	task.wait()
end

----------------------------------------------------------------
-- Solve detection: driven by whatever BlockSync has actually placed
----------------------------------------------------------------
local function checkSolved(info, cellsList)
	local byKey = {}
	for _, c in ipairs(cellsList) do
		byKey[c.col .. "," .. c.row] = c
	end
	for _, sc in ipairs(info.solveCells) do
		local c = byKey[sc[1] .. "," .. sc[2]]
		if not c then return false end
		if c.color ~= info.color then return false end
		if (c.level or 1) < info.level then return false end
	end
	return true
end

BlockSync.CellsChanged:Connect(function(bayModel, cellsList)
	local state = states[bayModel]
	if not state then
		local known = {}
		for k in pairs(states) do
			table.insert(known, k.Name)
		end
		warn(string.format("[HazardManager] no state for %s; known = [%s]",
			bayModel:GetFullName(), table.concat(known, ",")))
		return
	end

	-- Bays whose goal is an action rather than a placement own their own solved state; the
	-- crates there are the means, so filling cells must not short-circuit them.
	if state.info.solveMode == "switches" then
		return
	end

	state.setSolved(checkSolved(state.info, cellsList))
end)

print("[HazardManager] one obstacle per bay built for all " .. Config.NumBays .. " bays")
