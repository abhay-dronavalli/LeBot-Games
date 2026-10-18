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
local Lighting = game:GetService("Lighting")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local BayData = require(ReplicatedStorage:WaitForChild("BayData"))
local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))
local Mapping = require(ReplicatedStorage:WaitForChild("Mapping"))
local RunControl = require(ServerScriptService:WaitForChild("RunControl"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ObjectiveEvent = Remotes:WaitForChild("Objective")

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

-- Blocks are INTERCHANGEABLE. An obstacle cares how many cubes are in a cell -- the stack
-- height -- and never what colour they are, because the operator grabs whichever cube is to
-- hand on the real table. So a requirement only ever reads "a block here" or "a stack of N",
-- and every colour test has been stripped out of the solve path. Crates still SPAWN in their
-- colours; that is appearance, and the debug editor still picks one.
local function blockReq(level)
	return ((level or 1) > 1) and string.format("STACK x%d", level) or "BLOCK"
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

-- Who is standing in bay `i` right now. `pad` widens the test toward the entrance, so a bay
-- can put its objective on screen while the player is still on the approach catwalk sizing the
-- obstacle up. The y floor drops a player who has already fallen out of the world, which for a
-- void bay is most of them.
local function occupantsOf(i, pad)
	local zStart = bayZStart(i)
	local zEnd = zStart + Config.BayDepth
	local found = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		local ch = pl.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 and not isGhost(ch) then
			local p = hrp.Position
			if p.Z > zStart - (pad or 0) and p.Z < zEnd + 2
				and p.X > -2 and p.X < Config.BayWidth + 2 and p.Y > -8 then
				table.insert(found, {character = ch, humanoid = hum, position = p})
			end
		end
	end
	return found
end

-- Bays whose goal is an ACTION rather than a placement own state.solved themselves, and
-- checkSolved must not overwrite it from the cells list. Bay 1 throws levers; bay 3 walks a
-- generated route. Their solveCells, if any, degrade to an advisory hint.
local function ownsItsSolve(info)
	return info.solveMode == "switches" or info.solveMode == "action"
end

-- Objective HUD arbitration. Remotes.Objective is ONE channel, but every bay has an opinion
-- about what belongs on it. While bay 1 was the only driver, broadcasting was fine; the moment
-- a second bay started publishing, bay 1's loop -- which broadcasts a clear every 0.2s whenever
-- its own bay is empty -- began wiping the callout of the bay the player was actually standing
-- in, and bay 2's HUD only ever appeared in the gaps between those clears.
--
-- So no bay broadcasts any more. A bay addresses only the players inside it, and clears only a
-- player it was itself last showing something to. That also makes each bay's own stated intent
-- true -- "a player standing outside the bay isn't told to do anything" -- which broadcasting
-- never actually delivered.
local hudShownBy = setmetatable({}, {__mode = "k"})

-- Which single bay owns a player's HUD. Containment alone is not enough: a bay wants its
-- callout up while the player is still on the approach catwalk, but the gap between bays is
-- only Config.BayGap studs and the pad is a whole cell, so two neighbours' padded windows
-- overlap and both would claim anyone standing between them. Standing at z=57 showed bay 2's
-- callout while walking into bay 3.
--
-- So: the bay whose body you are actually inside always wins. Outside every body, the bay you
-- are walking TOWARDS wins over the one you just left, which is the direction the game runs.
local function hudBayFor(pos, pad)
	local approach, approachDist = nil, math.huge
	local trailing, trailingDist = nil, math.huge
	for idx = 1, Config.NumBays do
		local zStart = bayZStart(idx)
		local zEnd = zStart + Config.BayDepth
		if pos.Z >= zStart and pos.Z <= zEnd then
			return idx
		elseif pos.Z < zStart then
			local d = zStart - pos.Z
			if d <= pad and d < approachDist then
				approach, approachDist = idx, d
			end
		else
			local d = pos.Z - zEnd
			if d <= pad and d < trailingDist then
				trailing, trailingDist = idx, d
			end
		end
	end
	return approach or trailing
end

-- A refused placement has to be visible to the PLAYER, not just printed on the server.
--
-- The saw wall flashed its own refusals; every other bay was silent, so bay 3 turning away a
-- block that was not the next cell on its route looked exactly like the block never arriving.
-- You place, nothing happens, nothing says why. Held centrally so a bay gets this for free
-- rather than each builder reinventing it.
local flashText, flashUntil, flashBay = nil, 0, nil
local FLASH_SECONDS = 2.6

BlockSync.PlacementRejected:Connect(function(bayModel, cell, reason)
	local idx = tonumber(tostring(bayModel.Name):match("Bay(%d+)"))
	flashBay = idx
	flashUntil = os.clock() + FLASH_SECONDS
	flashText = reason and tostring(reason)
		or ("CANNOT PLACE AT (%s,%s)"):format(tostring(cell and cell.col), tostring(cell and cell.row))
end)

local function publishObjective(i, payload, pad)
	-- merge in any refusal this bay just made, unless the bay set its own
	if payload and flashBay == i and os.clock() < flashUntil and payload.flash == nil then
		payload.flash = flashText
	end
	local inside = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		local ch = pl.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 and not isGhost(ch) then
			local pos = hrp.Position
			if pos.X > -2 and pos.X < Config.BayWidth + 2 and pos.Y > -8
				and hudBayFor(pos, pad or 0) == i then
				inside[pl] = true
			end
		end
	end

	for _, pl in ipairs(Players:GetPlayers()) do
		if inside[pl] and payload then
			hudShownBy[pl] = i
			ObjectiveEvent:FireClient(pl, payload)
		elseif hudShownBy[pl] == i then
			-- only ever retract what this bay put up
			hudShownBy[pl] = nil
			ObjectiveEvent:FireClient(pl, nil)
		end
	end
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

-- SAW WALL: the bay seals behind you and a wall of chainsaws closes in from the FAR end. It
-- starts by the exit and comes toward the entrance, so walking in is never blocked and the wall
-- itself is the only thing between you and the way out. Two levers, mounted too high to reach
-- from the floor, are the escape: the crates are a LADDER to the answer rather than the answer
-- itself. Lever A kills the blades and arms Lever B; Lever B halts the wall and sinks it into
-- the floor, and that IS the exit -- there is no separate gate. The closing wall is the clock,
-- which makes Config.SawWallSeconds the one knob for this bay's difficulty.
--
-- Stalling the wall is a REWARD for killing the blades, never a way to skip that step:
--   blades live -> the wall cuts straight through a crate without slowing, and a crate cannot
--                  even be placed within Config.SawWallNoPlaceBand of the blades
--   blades dead -> nothing cuts, so the first crate in the path jams the wall, but only for
--                  Config.SawWallStallSeconds -- a crate buys a reprieve, never a permanent
--                  shield, and each crate's stall is spent once
-- A crate is never destroyed, because the real cube is still on the operator's table and the
-- game has to mirror it. That also makes the Lever B stack a shield once A is thrown, so the
-- player is never killed standing on the block that saved them.
BUILDERS.Saw = function(i, folder, info, state)
	local z0 = bayZStart(i)
	local zEnd = z0 + Config.BayDepth
	local midX = Config.BayWidth / 2

	-- Closes from the far end toward the entrance. A first version started the wall two studs
	-- inside the door, spanning the full width with CanCollide on, which blocked the player
	-- from entering the bay at all.
	local WALL_START = zEnd - 2
	local WALL_END = z0 + 2.5
	-- Tall enough that it cannot be jumped. A default jump clears about 12.8 studs of head
	-- height, so a 7.4 stud wall was a hurdle, not a wall -- the only way past is to sink it.
	local WALL_H = 16
	local WALL_Y = WALL_H / 2

	-- The wall runs in side channels rather than spanning the bay edge to edge, which is what
	-- keeps it clear of the wall-mounted levers: it sweeps PAST them instead of through them.
	local SIDE_T = 1.0                       -- side wall thickness
	local SIDE_FACE = SIDE_T / 2             -- inner face of the left side wall
	local WALL_X0 = SIDE_FACE + 0.6
	local WALL_X1 = Config.BayWidth - SIDE_FACE - 0.6
	local WALL_W = WALL_X1 - WALL_X0
	local TICK = 0.05
	-- Advance off measured elapsed time, not tick count: task.wait(0.05) actually sleeps a bit
	-- longer, which made a nominal 30s traverse take about 34s. The wall is this bay's clock,
	-- so SawWallSeconds has to mean real seconds.
	local studsPerSecond = (WALL_START - WALL_END) / Config.SawWallSeconds
	local lastTick = os.clock()

	-- paint the sweep lane, so the operator can see where a brake crate actually intercepts
	newPart("SweepLane", Vector3.new(Config.BayWidth - 1, 0.08, Config.BayDepth - 1),
		Vector3.new(midX, 0.06, z0 + Config.BayDepth / 2), Color3.fromRGB(120, 92, 22),
		Enum.Material.SmoothPlastic, folder, {Transparency = 0.6, CanQuery = false})

	----------------------------------------------------------------
	-- entry gate only. There is deliberately no exit gate: the saw wall is the exit barrier,
	-- and Lever B lowering it is what opens the way through.
	----------------------------------------------------------------
	local GATE_H = 14
	local entryGate = newPart("EntryGate", Vector3.new(Config.BayWidth, GATE_H, 1),
		Vector3.new(midX, -GATE_H / 2, z0), Color3.fromRGB(72, 68, 62),
		Enum.Material.DiamondPlate, folder, {CanCollide = true})

	local function slideGate(gate, up)
		TweenService:Create(gate, TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{CFrame = CFrame.new(gate.Position.X, up and GATE_H / 2 or -GATE_H / 2, gate.Position.Z)}):Play()
	end

	----------------------------------------------------------------
	-- the wall
	----------------------------------------------------------------
	-- Side channels. The bay had no side walls at all -- Border.Left/Right are 0.25 stud floor
	-- stripes you can walk straight over -- which is why the levers used to need a mount block
	-- jutting into the bay: there was nothing to bolt them to.
	for _, side in ipairs({{"Left", 0}, {"Right", Config.BayWidth}}) do
		newPart("SideWall" .. side[1], Vector3.new(SIDE_T, WALL_H, Config.BayDepth),
			Vector3.new(side[2], WALL_H / 2, z0 + Config.BayDepth / 2),
			Color3.fromRGB(64, 62, 60), Enum.Material.DiamondPlate, folder,
			{CanCollide = true})
		newPart("SideRail" .. side[1], Vector3.new(SIDE_T + 0.3, 0.5, Config.BayDepth),
			Vector3.new(side[2], WALL_H - 0.5, z0 + Config.BayDepth / 2),
			Color3.fromRGB(230, 170, 40), Enum.Material.Neon, folder, {CanQuery = false})
	end

	local frame = newPart("WallFrame", Vector3.new(WALL_W, WALL_H, 1.2),
		Vector3.new((WALL_X0 + WALL_X1) / 2, WALL_Y, WALL_START), Color3.fromRGB(58, 54, 50),
		Enum.Material.DiamondPlate, folder, {CanCollide = true})

	-- Two rows of blades now that there is a wall's worth of height to fill. The lower row is
	-- what you meet standing on the floor; the upper row is what you meet standing on a stack,
	-- so climbing never takes you above the danger.
	local blades = {}
	for col = 0, Config.BayCols - 1 do
		local bx = col * CELL + CELL / 2
		for row, by in ipairs({WALL_H * 0.28, WALL_H * 0.72}) do
			-- a Cylinder's flat faces point along X, so this is a vertical disc facing
			-- sideways and it spins about its own axis rather than tumbling
			local blade = newPart(("WallBlade%d_%d"):format(col, row),
				Vector3.new(0.4, 6.4, 6.4), Vector3.new(bx, by, WALL_START),
				Color3.fromRGB(208, 210, 216), Enum.Material.Metal, folder,
				{Shape = Enum.PartType.Cylinder})
			makeLethalPart(blade)
			table.insert(blades, {part = blade, x = bx, y = by})
		end
	end

	local sparks = newPart("Sparks", Vector3.new(Config.BayWidth - 2, 0.5, 0.5),
		Vector3.new(midX, 1.2, WALL_START), Color3.fromRGB(255, 200, 70),
		Enum.Material.Neon, folder, {Transparency = 1, CanQuery = false})

	local wallZ, spin, bladesLive = WALL_START, 0, true
	local sunk = false
	-- declared up here, not down with the run/reset helpers, because the placement guard below
	-- closes over it; left further down it resolved to a nil global and the guard allowed
	-- everything through
	local running = false
	-- a stall is spent per crate, so the wall cannot sit on the same one forever
	local stallSpent, stallCrate, stallStart = {}, nil, 0
	local flashText, flashUntil = "", 0

	local function placeWall(z)
		if sunk then
			return -- the lowering tween owns the CFrames now
		end
		frame.CFrame = CFrame.new(midX, WALL_Y, z)
		for _, b in ipairs(blades) do
			b.part.CFrame = CFrame.new(b.x, WALL_Y - 0.4, z) * CFrame.Angles(spin, 0, 0)
		end
		-- sparks sit on the near face, the side the player is on
		sparks.CFrame = CFrame.new(midX, 1.2, z - 1.2)
	end

	local function setBladesLive(live)
		bladesLive = live
		for _, b in ipairs(blades) do
			b.part:SetAttribute("Live", live)
			b.part.Color = live and Color3.fromRGB(208, 210, 216) or Color3.fromRGB(96, 98, 104)
		end
	end

	-- Lever B's payoff: the wall drops into the floor and you continue out over it. Collision
	-- is cleared once it is low enough to step across.
	local function sinkWall()
		sunk = true
		-- deep enough that a WALL_H wall's top ends below the floor, not just its middle
		local downY = -(WALL_H / 2) - 1.5
		local info = TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
		TweenService:Create(frame, info, {CFrame = CFrame.new(midX, downY, wallZ)}):Play()
		for _, b in ipairs(blades) do
			TweenService:Create(b.part, info,
				{CFrame = CFrame.new(b.x, downY - 0.4, wallZ) * CFrame.Angles(spin, 0, 0)}):Play()
		end
		task.delay(0.9, function()
			frame.CanCollide = false
		end)
	end

	-- Nearest crate the wall is about to meet. It travels toward -Z, so the next thing it
	-- meets is whatever sits just in front of its near face.
	local function crateInPath(z)
		if not Config.SawWallBrakeEnabled then
			return nil
		end
		for _, c in ipairs(folder.Parent:GetChildren()) do
			if c.Name == "Crate" then
				local b = c:FindFirstChild("Base")
				if b and b.Position.Z < z and z - b.Position.Z < 3.1 then
					return b
				end
			end
		end
		return nil
	end

	-- Refuse deliveries that would stall the wall before the blades are dead. The band is
	-- measured from the blades, so a crate placed early -- while the wall is still far away --
	-- is fine; it is only dropping one just in front of live blades that is turned away.
	-- Rejections are parked by BlockSync and re-offered when Lever A changes the answer.
	local showNotice
	BlockSync.setPlacementGuard(folder.Parent, function(cell)
		if not running or not bladesLive then
			return true
		end
		local cellZ = cellCenter(i, cell.col, cell.row).Z
		if cellZ > wallZ - Config.SawWallNoPlaceBand then
			if showNotice then
				showNotice("BLADES LIVE - CANNOT DROP THERE")
			end
			return false, "blades live"
		end
		return true
	end)

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
		-- Live cubes carry an IsCrate attribute; the DebugMode path's crates are still matched
		-- by name. Keying on the attribute means the live path does not have to name a cube
		-- sitting on top of a stack "Topper" just to satisfy a string compare.
		if not hit then
			return 0
		end
		local inst = hit.Instance
		if not inst:GetAttribute("IsCrate")
			and inst.Name ~= "Base" and inst.Name ~= "Topper" then
			return 0
		end
		return inst.Position.Y + inst.Size.Y / 2
	end

	-- A lever belongs to ONE stack height, not to a minimum.
	--
	-- `standLevel` is how many crates you stand on to work it: 1 for A, 2 for B. The height and
	-- the gate are both derived from that, so they cannot drift apart, and they follow the real
	-- cube size automatically. Standing higher than the lever no longer works -- a 2-stack
	-- cannot reach down and flip A -- which is what makes each lever cost its own cubes.
	local CUBE = Mapping.cubeStuds()
	local LEVEL_TOLERANCE = CUBE * 0.45       -- comfortably inside one cube either way

	local function standTopFor(level)
		return level * CUBE
	end

	local function buildLever(spec)
		local inward = (spec.side == "left") and 1 or -1
		local level = spec.standLevel or 1
		local standTop = standTopFor(level)
		-- chest height above the crate you are standing on
		local y = standTop + 2.4
		-- flush against the side wall's inner face, not on a block jutting into the bay
		local face = (spec.side == "left") and SIDE_FACE or (Config.BayWidth - SIDE_FACE)
		local x = face + inward * 0.18
		local z = cellCenter(i, spec.cell[1], spec.cell[2]).Z

		local lv = {id = spec.id, phase = DORMANT, level = level, standTop = standTop}

		-- A backplate bolted to the wall, 0.36 studs proud of it -- the wall is the housing now.
		lv.mount = newPart("Lever" .. spec.id .. "Plate", Vector3.new(0.36, 3.2, 3.2),
			Vector3.new(x, y, z), Color3.fromRGB(40, 40, 46), Enum.Material.DiamondPlate, folder)
		lv.beacon = newPart("Lever" .. spec.id .. "Beacon", Vector3.new(0.5, 0.5, 2.8),
			Vector3.new(x + inward * 0.2, y + 2.1, z), Color3.fromRGB(34, 34, 38),
			Enum.Material.Neon, folder, {CanQuery = false})

		-- A painted band on the wall at the height you have to be standing at, so the level a
		-- lever wants is readable from across the bay instead of guessed at.
		lv.stripe = newPart("Lever" .. spec.id .. "Level", Vector3.new(0.14, 0.35, 5.5),
			Vector3.new(face + inward * 0.1, standTop + 0.2, z),
			Color3.fromRGB(120, 120, 130), Enum.Material.Neon, folder, {CanQuery = false})

		lv.pivot = Vector3.new(x + inward * 0.45, y - 1.0, z)
		lv.handle = newPart("Lever" .. spec.id .. "Handle", Vector3.new(0.45, HANDLE_LEN, 0.45),
			lv.pivot, Color3.fromRGB(190, 58, 52), Enum.Material.Metal, folder)
		lv.knob = newPart("Lever" .. spec.id .. "Knob", Vector3.new(0.85, 0.85, 0.85),
			lv.pivot, Color3.fromRGB(235, 80, 68), Enum.Material.SmoothPlastic, folder,
			{Shape = Enum.PartType.Ball})

		-- Swing the handle out into the bay, not along it. Rotating about X tipped the lever
		-- down the lane, which is why the levers looked like they were aimed at nothing in
		-- particular -- a wall lever has to flip toward whoever is standing in front of it.
		-- About Z, +Y turns toward -X, so the left wall (inward = +1) needs the negative.
		function lv.setAngle(deg)
			local base = CFrame.new(lv.pivot) * CFrame.Angles(0, 0, math.rad(-inward * deg))
			lv.handle.CFrame = base * CFrame.new(0, HANDLE_LEN / 2, 0)
			lv.knob.CFrame = base * CFrame.new(0, HANDLE_LEN, 0)
		end
		lv.setAngle(0)

		lv.light = Instance.new("PointLight")
		lv.light.Range = 18
		lv.light.Brightness = 0
		lv.light.Color = Color3.fromRGB(90, 255, 130)
		lv.light.Parent = lv.mount

		lv.levelText = ("LEVEL %d  (%s)"):format(level,
			level == 1 and "1 crate" or (level .. " crates stacked"))
		lv.label = addLabel(folder, ("LEVER %s  -  %s"):format(spec.id, lv.levelText),
			Vector3.new(x + inward * 1.2, y + 3.6, z), Color3.fromRGB(130, 130, 140))

		-- A real wall lever: climb to it and hold E. ProximityPrompt gives the hold-to-act UI
		-- and the key binding for free, and brushing past no longer throws anything -- the old
		-- Touched version fired the moment any body part grazed the housing.
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Flip Lever"
		prompt.ObjectText = "Lever " .. spec.id
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = Config.SawLeverHoldSeconds
		prompt.MaxActivationDistance = 9
		prompt.RequiresLineOfSight = false
		prompt.Enabled = false
		prompt.Parent = lv.mount
		lv.prompt = prompt

		prompt.Triggered:Connect(function(player)
			local ch = player.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 or isGhost(ch) or lv.phase ~= ARMED then
				return
			end
			-- Same level, not "at least this high". Standing on a taller stack is as wrong as
			-- standing on the floor: each lever costs its own crates, and that is the whole
			-- cube budget argument this bay is built on.
			if math.abs(supportHeight(ch) - lv.standTop) > LEVEL_TOLERANCE then
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
		if lv.prompt then
			lv.prompt.Enabled = (phase == ARMED)
		end
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
	-- On-screen objective. Pushed whenever the state changes, and a few times a second while
	-- the wall is moving so the countdown stays live. Sending nil clears the HUD, so a player
	-- standing outside the bay isn't told to do anything.
	----------------------------------------------------------------
	local lastPush = 0

	local function pushObjective()
		lastPush = os.clock()
		if not running and not state.solved then
			publishObjective(i, nil, 0)
			return
		end

		local p = {title = "BAY 1  -  SAW WALL"}

		-- A checklist, not a single line. Both levers are always shown with their state and
		-- the level each one wants, so the plan is readable at a glance instead of being
		-- revealed one step at a time.
		local function leverLine(lv, label)
			if not lv then
				return nil
			end
			local mark = (lv.phase == THROWN) and "[x]"
				or (lv.phase == ARMED) and "[ ]" or "[-]"
			local statusText = (lv.phase == THROWN) and "done"
				or (lv.phase == ARMED) and "ready" or "locked"
			return ("%s  LEVER %s  -  %s  -  %s"):format(mark, lv.id, label, statusText)
		end
		p.steps = {
			leverLine(leverA, "stand on 1 crate, kill the blades"),
			leverLine(leverB, "stand on 2 stacked, drop the wall"),
		}

		if state.solved then
			p.task = "CLEARED"
			p.hint = "The wall is down -- walk out over it."
			p.tone = "ok"
		elseif bladesLive then
			p.task = "LEVER A  -  KILL THE BLADES"
			p.hint = "Left wall, middle row. Stand on ONE crate -- not two -- and hold E."
			p.tone = "danger"
		else
			p.task = "LEVER B  -  STOP THE WALL"
			p.hint = "Right wall by the entrance. Stand on the stacked PAIR and hold E."
			p.tone = "warn"
		end
		p.note = bladesLive
			and "Blades live: crates cannot be dropped in front of them, and the wall cuts straight through."
			or "Blades dead: the next crate in the lane jams the wall, once, for "
				.. Config.SawWallStallSeconds .. "s."

		if running and not state.solved then
			if stallCrate then
				p.timerLabel = "STALLED"
				p.timer = math.max(0, Config.SawWallStallSeconds - (os.clock() - stallStart))
				p.timerTone = "ok"
			else
				p.timerLabel = "WALL REACHES YOU IN"
				p.timer = math.max(0, (wallZ - WALL_END) / studsPerSecond)
			end
		end

		if os.clock() < flashUntil then
			p.flash = flashText
		end
		publishObjective(i, p, 0)
	end

	----------------------------------------------------------------
	-- run / reset. The obstacle stays dormant until someone is actually inside, which also
	-- gives the reset for free: when the bay empties unsolved, everything goes back.
	-- (`running` is declared further up, with the wall state.)
	----------------------------------------------------------------
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
		sunk = false
		frame.CanCollide = true
		wallZ = WALL_START
		spin = 0
		lastTick = os.clock()
		setBladesLive(true)
		placeWall(wallZ)
		slideGate(entryGate, true)
		setPhase(leverA, ARMED)
		setPhase(leverB, DORMANT)
		pushObjective()
	end

	local function resetRun()
		running = false
		sunk = false
		stallSpent, stallCrate, stallStart = {}, nil, 0
		frame.CanCollide = true
		wallZ = WALL_START
		setBladesLive(true)
		placeWall(wallZ)
		sparks.Transparency = 1
		slideGate(entryGate, false)
		setPhase(leverA, DORMANT)
		setPhase(leverB, DORMANT)
		pushObjective()
	end

	-- Debug/GameState reset. A switch-driven bay cannot be un-solved by clearing cells, since
	-- its CellsChanged handler returns early, so without this hook the bay stays open for the
	-- rest of the session and the demo is a one-shot.
	function state.reset()
		resetRun()
	end

	if leverA then
		function leverA.onThrow()
			setPhase(leverA, THROWN)
			setBladesLive(false)
			setPhase(leverB, ARMED)
			-- the operator may already have a cube down that the guard turned away; with the
			-- blades dead it is allowed now, so the game owes them that crate
			BlockSync.retryRejected(folder.Parent)
			pushObjective()
			print("[HazardManager] saw wall: Lever A thrown, blades dead")
		end
	end

	if leverB then
		function leverB.onThrow()
			setPhase(leverB, THROWN)
			running = false
			sparks.Transparency = 1
			sinkWall()
			print("[HazardManager] saw wall: Lever B thrown, wall halted and lowering")
			if state.setSolved then
				state.setSolved(true)
			end
			pushObjective()
		end
	end

	local notice = addLabel(folder, "", Vector3.new(midX, 7.5, z0 + 5),
		Color3.fromRGB(255, 140, 90))
	notice.Text = ""
	local noticeUntil = 0
	function showNotice(text)
		notice.Text = text
		noticeUntil = os.clock() + 2.5
		flashText, flashUntil = text, os.clock() + 2.5
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
				if blocker and not bladesLive and not stallSpent[blocker] then
					if stallCrate ~= blocker then
						stallCrate, stallStart = blocker, now
					end
					local left = Config.SawWallStallSeconds - (now - stallStart)
					if left > 0 then
						advance = 0 -- jammed: no spinning blade left to cut with
						showNotice(string.format("WALL STALLED - %ds", math.ceil(left)))
					else
						-- that crate's reprieve is used up; the wall grinds past it
						stallSpent[blocker] = true
						stallCrate = nil
					end
				end
				-- sparks while live blades are cutting through a crate they cannot stop on
				sparks.Transparency = (blocker and bladesLive) and (0.25 + math.random() * 0.5) or 1

				wallZ = math.max(wallZ - advance, WALL_END)
				placeWall(wallZ)

				for _, o in ipairs(occupants) do
					-- past the near face (tunnelled through), or pinned on the entry gate
					if o.position.Z > wallZ + 0.8 or wallZ <= WALL_END + 0.05 then
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

					-- Say WHICH WAY you are wrong. "Stack higher" was a lie half the time:
					-- standing on a 2-stack at lever A now fails, and being told to stack
					-- higher would send you the wrong direction entirely.
					local verdict = nil
					for _, o in ipairs(occupants) do
						if (o.position - lv.mount.Position).Magnitude < 8 then
							local h = supportHeight(o.character)
							local d = h - lv.standTop
							if d < -LEVEL_TOLERANCE then
								verdict = (h < 0.5) and "NEED " .. lv.level
									.. (lv.level == 1 and " CRATE" or " CRATES")
									or "STACK HIGHER"
							elseif d > LEVEL_TOLERANCE then
								verdict = "TOO HIGH  -  STAND ONE LOWER"
							end
						end
					end
					if verdict then
						lv.label.Text = "LEVER " .. lv.id .. "  -  " .. verdict
						lv.label.TextColor3 = Color3.fromRGB(255, 150, 90)
					else
						lv.label.Text = "LEVER " .. lv.id .. "  -  LIVE  (HOLD E)"
						lv.label.TextColor3 = Color3.fromRGB(120, 255, 150)
					end
				end
			end

			if notice.Text ~= "" and os.clock() > noticeUntil then
				notice.Text = ""
			end
			if os.clock() - lastPush > 0.2 then
				pushObjective()
			end

			task.wait(TICK)
		end
	end)

	function state.onSolved() end
end

-- VOID: the floor is gone over `coverRows`, and the gap is deliberately wider than a jump --
-- so the crates are not a shortcut across, they ARE the bridge. The arithmetic that makes that
-- true: stock JumpHeight 7.2 and WalkSpeed 16 under Gravity 196.2 give 0.54s of air and 8.67
-- studs of flat travel, while the uncovered rows span 16. Mounting the far side higher, or
-- widening the gap further, would both be redundant -- one cell of void is already unjumpable.
--
-- Nothing in this bay is lethal except the drop, which satisfies the safe-footing rule for
-- free: the bridge you built is the only place there is to stand.
BUILDERS.Void = function(i, folder, info, state)
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	local floor = bay and bay:FindFirstChild("Floor")
	local rows = info.coverRows or {0, 1, 2}

	local z0 = bayZStart(i)
	local wholeBay = #rows >= Config.BayRows
	-- The near lip is the bay entrance; the far lip is wherever solid ground resumes. Both are
	-- derived from `coverRows`, so changing that one field moves the geometry with it.
	local nearZ = z0
	local farZ = wholeBay and (z0 + Config.BayDepth)
		or (z0 + (math.max(table.unpack(rows)) + 1) * CELL)
	local span = farZ - nearZ
	local midZ = (nearZ + farZ) / 2
	local W = Config.BayWidth
	local depth = Config.VoidShaftDepth

	local AMBER = Color3.fromRGB(255, 176, 40)
	local GREEN = Color3.fromRGB(120, 240, 140)
	local SHAFT = Color3.fromRGB(14, 14, 18)

	-- The crates here ARE the floor, so they sit flush with it rather than on top of it. One
	-- cube of sink: without it the bridge stands a full cube proud of the walkway and crossing
	-- the gap means hopping up onto every slab and back down again, which is not what "the
	-- blocks are the bridge" means.
	bay:SetAttribute("CrateSink", Mapping.cubeStuds())

	----------------------------------------------------------------
	-- Cut the baked floor back so only the rows outside `coverRows` keep solid ground.
	-- Absolute rather than relative, so re-running the builder is idempotent.
	----------------------------------------------------------------
	if floor then
		if wholeBay then
			floor.Transparency = 1
			floor.CanCollide = false
			floor.CanTouch = false
		else
			local keptDepth = Config.BayDepth - span
			floor.Size = Vector3.new(W, 1, keptDepth)
			floor.CFrame = CFrame.new(W / 2, -0.5, farZ + keptDepth / 2)
		end
	end

	----------------------------------------------------------------
	-- The shaft. Purely presentational: the drop has to read as a drop from floor level, or
	-- the bay looks like a texture glitch rather than somewhere you can die. Every piece here
	-- is CanCollide = false so nothing catches a falling player half way down.
	----------------------------------------------------------------
	local function shaftWall(name, size, pos)
		newPart(name, size, pos, SHAFT, Enum.Material.Slate, folder, {CanQuery = false})
	end
	shaftWall("ShaftLeft", Vector3.new(0.5, depth, span), Vector3.new(0.25, -depth / 2, midZ))
	shaftWall("ShaftRight", Vector3.new(0.5, depth, span), Vector3.new(W - 0.25, -depth / 2, midZ))
	shaftWall("ShaftFar", Vector3.new(W, depth, 0.5), Vector3.new(W / 2, -depth / 2, farZ - 0.25))
	shaftWall("ShaftNear", Vector3.new(W, depth, 0.5), Vector3.new(W / 2, -depth / 2, nearZ + 0.25))
	shaftWall("ShaftFloor", Vector3.new(W, 0.5, span), Vector3.new(W / 2, -depth, midZ))

	-- Cut-edge fascia: shows the thickness of the slab you are standing on, at both lips.
	local function fascia(name, size, pos)
		newPart(name, size, pos, Color3.fromRGB(78, 80, 88), Enum.Material.Metal, folder,
			{CanQuery = false})
	end
	fascia("EdgeNear", Vector3.new(W, 1.4, 0.7), Vector3.new(W / 2, -0.7, nearZ + 0.35))
	if not wholeBay then
		fascia("EdgeFar", Vector3.new(W, 1.4, 0.7), Vector3.new(W / 2, -0.7, farZ - 0.35))
	end
	fascia("EdgeLeft", Vector3.new(0.7, 1.4, span), Vector3.new(0.35, -0.7, midZ))
	fascia("EdgeRight", Vector3.new(0.7, 1.4, span), Vector3.new(W - 0.35, -0.7, midZ))

	-- Hazard striping on both lips. These are the parts that go green on solve, so they are
	-- the bay's whole state readout -- amber means the gap is still open.
	local lips = {}
	local DASH = 2
	for x = 0, W - DASH, DASH * 2 do
		local function dash(name, z)
			local p = newPart(name, Vector3.new(DASH, 0.22, 0.9),
				Vector3.new(x + DASH / 2, 0.11, z), AMBER, Enum.Material.Neon, folder,
				{CanQuery = false})
			table.insert(lips, p)
		end
		dash("LipNear", nearZ + 0.45)
		if not wholeBay then
			dash("LipFar", farZ - 0.45)
		end
	end

	-- Warning lights down the shaft, so the depth is legible rather than just dark. Range is
	-- capped just under the spacing so each one reads as a separate marker going down and none
	-- of them spills back up through the opening to light the bay floor from below.
	for y = -Config.VoidLightSpacing, -depth + 4, -Config.VoidLightSpacing do
		local anchor = newPart("ShaftLight", Vector3.new(0.4, 0.4, 0.4),
			Vector3.new(W / 2, y, midZ), nil, nil, folder, {Transparency = 1, CanQuery = false})
		local l = Instance.new("PointLight")
		l.Color = Color3.fromRGB(255, 70, 40)
		l.Brightness = 1.1
		l.Range = Config.VoidLightSpacing - 2
		l.Parent = anchor
	end

	----------------------------------------------------------------
	-- Kill plane. Sits above the shaft floor so the death happens in open air rather than on
	-- contact with scenery, and spans wider than the bay so stepping off sideways still lands
	-- in it.
	----------------------------------------------------------------
	local catcher = newPart("VoidCatcher", Vector3.new(W + 12, 2, span + 4),
		Vector3.new(W / 2, -depth + 4, midZ), Color3.fromRGB(0, 0, 0),
		Enum.Material.SmoothPlastic, folder, {Transparency = 1})
	catcher.CanTouch = true
	catcher.Touched:Connect(function(hit)
		local _, hum = characterFrom(hit)
		if hum and hum.Health > 0 then
			hum.Health = 0
		end
	end)

	----------------------------------------------------------------
	-- Placement holograms: a crate-sized ghost at each solveCell, so the player can read the
	-- cell to call out instead of guessing it off the debug grid. One disappears as its cell
	-- is filled, which makes "what is left to do" visible in world as well as on the HUD.
	--
	-- Amber rather than tinted to a required colour: any block fits, so a coloured ghost would
	-- be telling the operator to go and find a cube they do not need.
	----------------------------------------------------------------
	local tint = AMBER
	local ghosts = {}
	for _, sc in ipairs(info.solveCells or {}) do
		local col, row = sc[1], sc[2]
		local c = cellCenter(i, col, row)
		local box = newPart("GhostCrate", Vector3.new(4, 4, 4), Vector3.new(c.X, 2, c.Z),
			tint, Enum.Material.ForceField, folder, {Transparency = 0.55, CanQuery = false})
		local label = addLabel(folder, string.format("%s  (%d,%d)", blockReq(info.level), col, row),
			Vector3.new(c.X, 6.5, c.Z), tint)
		ghosts[col .. "," .. row] = {box = box, label = label}
	end

	local function showGhost(key, visible)
		local g = ghosts[key]
		if not g then
			return
		end
		g.box.Transparency = visible and 0.55 or 1
		g.label.Visible = visible
	end

	----------------------------------------------------------------
	-- Objective HUD. No countdown: this bay has no clock of its own, and inventing one here
	-- would be a mechanic rather than an obstacle. The task line is the cell callout instead,
	-- which is exactly what the operator needs shouted at them.
	----------------------------------------------------------------
	local filled = {}

	local function nextNeeded()
		for _, sc in ipairs(info.solveCells or {}) do
			local key = sc[1] .. "," .. sc[2]
			if not filled[key] then
				return sc, key
			end
		end
		return nil
	end

	-- One description of how the bay looks, driven off what has actually landed rather than
	-- off state.solved -- buildBay's setSolved only calls onSolved on the way IN, so hanging
	-- the lip colour off that left the bay still showing "cleared" after a crate was lifted
	-- back out of it.
	local function refresh()
		local complete = (nextNeeded() == nil)
		for _, p in ipairs(lips) do
			p.Color = complete and GREEN or AMBER
		end
		for key in pairs(ghosts) do
			showGhost(key, not filled[key])
		end
	end

	-- No occupancy test here: publishObjective only ever reaches players standing in this bay,
	-- and clears the rest, so the payload is built unconditionally.
	local function pushObjective()
		local p = {title = string.format("BAY %d  -  THE VOID", i)}
		if state.solved then
			p.task = "CLEARED"
			p.hint = "The bridge is in -- jump across to the exit."
			p.tone = "ok"
		else
			local sc = nextNeeded()
			local remaining = 0
			for _, s2 in ipairs(info.solveCells or {}) do
				if not filled[s2[1] .. "," .. s2[2]] then
					remaining += 1
				end
			end
			if sc then
				p.task = string.format("%s  ->  COL %d, ROW %d",
					blockReq(info.level), sc[1], sc[2])
			else
				p.task = blockReq(info.level)
			end
			p.hint = (remaining > 1)
				and string.format("No floor for %d studs. Call out both cells -- the crates are the bridge.", span)
				or "One more block, then jump from block to block."
			p.tone = (remaining > 1) and "danger" or "warn"
		end
		publishObjective(i, p, CELL)
	end

	-- Track what has actually landed, for the holograms and the callout. Solve detection
	-- itself stays where it belongs -- checkSolved owns state.solved for a placement bay.
	BlockSync.CellsChanged:Connect(function(bayModel, cellsList)
		if bayModel ~= bay then
			return
		end
		filled = {}
		for _, c in ipairs(cellsList) do
			if (c.level or 1) >= info.level then
				filled[c.col .. "," .. c.row] = true
			end
		end
		refresh()
	end)

	-- Both hooks share refresh() so there is exactly one description of how the bay looks.
	state.onSolved = refresh

	function state.reset()
		filled = {}
		refresh()
	end

	-- The HUD follows occupancy: padded toward the entrance so the callout is already on
	-- screen while the player is still on the approach catwalk, reading the gap.
	task.spawn(function()
		while true do
			pushObjective()
			task.wait(0.2)
		end
	end)
end

-- LASER WALK: the whole 4x3 grid is lethal, and the single yellow crate is the only thing that
-- switches a cell off. You cross by having the operator walk that ONE crate ahead of you, cell
-- by cell, along a route only they can see.
--
-- The three rules that make it a puzzle rather than a chore:
--
--   * A cell holding the crate is safe. Nothing else is, ever.
--   * Only the NEXT cell of the route accepts the crate -- every other cell refuses the
--     delivery -- so the operator cannot shortcut straight down a column.
--   * The cell the crate just left stays safe for Config.LaserCooldownSeconds, counted from
--     the moment the crate SEATS in its new cell, not from when it was lifted. That matters:
--     one arm move is ~11s of flight, so a cooldown started at lift would be spent before the
--     crate even landed, and the bay would be a race against the arm instead of a race across
--     the floor.
--
-- The route is generated per run and the player can't see it, so the operator's overlay is
-- load-bearing: Bridge.send publishes the next cell to the physical side every time it changes.
BUILDERS.LaserWalk = function(i, folder, info, state)
	-- The cube is a TOKEN here, not an object. The operator slides a real cube across the real
	-- mat and the matching tile goes quiet; the player walks on the floor, because the pad is
	-- what kills and a safe pad does not. A crate standing in the cell was scenery -- and
	-- scenery that reads as "climb me" in the one bay where climbing is not the point.
	-- (the attribute is set just below, once `bay` is in scope)

	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	if bay then
		bay:SetAttribute("VirtualCrates", true)
	end
	local COLS, ROWS = Config.BayCols, Config.BayRows

	-- Arming has to trigger from the APPROACH, not from inside the bay. Every cell is lethal
	-- until the first crate lands, so a bay that only armed once somebody was standing in it
	-- could only ever be armed by somebody dying in it. One cell of slack puts the player on
	-- the catwalk, where they can read the callout and wait for the operator's first placement.
	local ARM_PAD = CELL

	local RED = Color3.fromRGB(255, 0, 0)
	local AMBER = Color3.fromRGB(255, 176, 40)
	local GREEN = Color3.fromRGB(120, 240, 140)

	local function keyOf(c, r)
		return c .. "," .. r
	end

	----------------------------------------------------------------
	-- Per-cell hazard. The floor pad is the authoritative killer -- it is the thing you
	-- actually stand on, so it cannot be stepped over -- and the crossed beams above it are
	-- what make the cell legible from across the bay.
	----------------------------------------------------------------
	local cells = {}
	for col = 0, COLS - 1 do
		for row = 0, ROWS - 1 do
			local c = cellCenter(i, col, row)
			local pad = newPart("CellPad", Vector3.new(CELL - 0.5, 0.12, CELL - 0.5),
				Vector3.new(c.X, 0.07, c.Z), RED, Enum.Material.Neon, folder,
				{Transparency = 0.7, CanQuery = false})
			makeLethalPart(pad)

			local beams = {}
			for _, y in ipairs({1.6, 4.4, 7.2}) do
				local across = newPart("CellBeam", Vector3.new(CELL - 0.2, 0.16, 0.16),
					Vector3.new(c.X, y, c.Z), RED, Enum.Material.Neon, folder,
					{Transparency = 0.15, CanQuery = false})
				local along = newPart("CellBeam", Vector3.new(0.16, 0.16, CELL - 0.2),
					Vector3.new(c.X, y, c.Z), RED, Enum.Material.Neon, folder,
					{Transparency = 0.15, CanQuery = false})
				makeLethalPart(across)
				makeLethalPart(along)
				table.insert(beams, across)
				table.insert(beams, along)
			end

			-- The number goes ON THE TILE. How long until the ground under you turns lethal is
			-- the most urgent thing in this bay, and a line in a panel at the top of the screen
			-- is the wrong place for it -- you are looking at your feet, picking the next step.
			-- SurfaceGui rather than Billboard: a flat number reads as painted floor marking,
			-- and a Billboard adorned to a part has already failed to render once here.
			local sg = Instance.new("SurfaceGui")
			sg.Face = Enum.NormalId.Top
			sg.LightInfluence = 0
			sg.PixelsPerStud = 36
			sg.Adornee = pad
			sg.Enabled = false
			sg.Parent = pad
			local count = Instance.new("TextLabel")
			count.AnchorPoint = Vector2.new(0.5, 0.5)
			count.Position = UDim2.new(0.5, 0, 0.5, 0)
			count.Size = UDim2.new(0.7, 0, 0.7, 0)
			count.BackgroundTransparency = 1
			count.Font = Enum.Font.GothamBold
			count.TextScaled = true
			count.TextColor3 = Color3.fromRGB(20, 14, 6)
			count.TextStrokeTransparency = 0.35
			count.Rotation = -90       -- a Top-face GUI's axes run across the bay
			count.Text = ""
			count.Parent = sg

			cells[keyOf(col, row)] = {col = col, row = row, pad = pad, beams = beams,
				live = true, countGui = sg, count = count}
		end
	end

	-- A cell is only ever one of these three, and the pad colour says which from anywhere.
	local LIVE, SAFE, COOLING = "live", "safe", "cooling"
	local function setCellState(cell, mode, flash)
		cell.live = (mode == LIVE)
		if cell.countGui then
			cell.countGui.Enabled = (mode == COOLING)
		end
		for _, b in ipairs(cell.beams) do
			b:SetAttribute("Live", cell.live)
			b.Transparency = cell.live and 0.15 or 1
		end
		cell.pad:SetAttribute("Live", cell.live)
		if mode == LIVE then
			cell.pad.Color = RED
			cell.pad.Transparency = 0.7
		elseif mode == SAFE then
			cell.pad.Color = GREEN
			cell.pad.Transparency = 0.45
		else
			cell.pad.Color = AMBER
			-- the pulse IS the warning: it speeds up as the cooldown runs out
			cell.pad.Transparency = flash and 0.25 or 0.6
		end
	end

	----------------------------------------------------------------
	-- Route generation. A simple (non-repeating) orthogonal walk that starts on the entrance
	-- row and finishes on the exit row, so the bay is genuinely crossed. Randomised DFS with
	-- backtracking -- the grid is 12 cells, so this is instant and always finds one.
	----------------------------------------------------------------
	local function shuffled(t)
		for a2 = #t, 2, -1 do
			local b2 = math.random(a2)
			t[a2], t[b2] = t[b2], t[a2]
		end
		return t
	end

	local function routeOfLength(target)
		local best, path, seen = nil, {}, {}

		local function dfs(col, row)
			if best then
				return
			end
			if #path == target then
				if row == ROWS - 1 then
					best = table.clone(path)
				end
				return
			end
			for _, d in ipairs(shuffled({{1, 0}, {-1, 0}, {0, 1}, {0, -1}})) do
				local nc, nr = col + d[1], row + d[2]
				local k = keyOf(nc, nr)
				if nc >= 0 and nc < COLS and nr >= 0 and nr < ROWS and not seen[k] then
					seen[k] = true
					table.insert(path, {nc, nr})
					dfs(nc, nr)
					table.remove(path)
					seen[k] = nil
					if best then
						return
					end
				end
			end
		end

		for _, sc in ipairs(shuffled({0, 1, 2, 3})) do
			path, seen = {{sc, 0}}, {[keyOf(sc, 0)] = true}
			dfs(sc, 0)
			if best then
				return best
			end
		end
		return nil
	end

	local function generateRoute()
		local lo, hi = Config.LaserRouteMin, Config.LaserRouteMax
		-- try the requested length first, then shorter, so an unlucky target can't leave the
		-- bay unplayable
		local want = math.random(lo, hi)
		for len = want, lo, -1 do
			local r = routeOfLength(len)
			if r then
				return r
			end
		end
		return routeOfLength(lo) or {{1, 0}, {1, 1}, {1, 2}}
	end

	----------------------------------------------------------------
	-- Run state
	----------------------------------------------------------------
	local route, step = nil, 0      -- step = how many route cells the crate has occupied
	local blockKey = nil            -- cell the crate is in; survives the crate being in flight
	local cooling = {}              -- [cellKey] = os.clock() when it goes live again
	local lastVacated = nil         -- the cell the crate just left: where the player is standing
	local running = false
	local flashText, flashUntil = nil, 0

	-- Optional: the physical side's overlay. Bridge only exists on branches that have the real
	-- robot link, and may be offline, so this is best-effort and the HUD always carries the
	-- same information for solo play.
	local Bridge
	do
		local mod = ServerScriptService:FindFirstChild("Bridge")
		if mod then
			local ok, result = pcall(require, mod)
			if ok then
				Bridge = result
			end
		end
	end

	local function nextCell()
		return route and route[step + 1] or nil
	end

	local lastEmitted = nil
	local function emitTarget()
		if not Bridge or not Bridge.send then
			return
		end
		local ok = pcall(function()
			if Bridge.isConnected and not Bridge.isConnected() then
				return
			end
			local n = nextCell()
			local sig = n and (n[1] .. "," .. n[2] .. "@" .. (step + 1)) or "done"
			if sig == lastEmitted then
				return
			end
			lastEmitted = sig
			Bridge.send({
				t = "target",
				bay = i,
				level = info.level,
				col = n and n[1] or nil,
				row = n and n[2] or nil,
				step = n and (step + 1) or nil,
				of = route and #route or nil,
				done = (n == nil),
			})
		end)
		if not ok then
			lastEmitted = nil
		end
	end

	local function armRun()
		running = true
		route = generateRoute()
		step = 0
		blockKey = nil
		cooling = {}
		lastVacated = nil
		lastEmitted = nil
		local parts = {}
		for _, c in ipairs(route) do
			table.insert(parts, string.format("(%d,%d)", c[1], c[2]))
		end
		print(string.format("[HazardManager] laser walk: route of %d -> %s",
			#route, table.concat(parts, " ")))
		emitTarget()
	end

	local function disarm()
		running = false
		route = nil
		step = 0
		blockKey = nil
		cooling = {}
		lastVacated = nil
		lastEmitted = nil
		emitTarget()
	end

	----------------------------------------------------------------
	-- Placement guard: only the next cell of the route takes the crate. A refusal is parked by
	-- BlockSync rather than discarded -- the operator's cube is still on the real table, so the
	-- game owes them the placement the moment the answer changes.
	----------------------------------------------------------------
	if bay then
		BlockSync.setPlacementGuard(bay, function(cell)
			local n = nextCell()
			if not n then
				return false, "ROUTE COMPLETE"
			end
			if cell.col == n[1] and cell.row == n[2] then
				return true
			end
			return false, string.format("NOT THE NEXT CELL - COL %d, ROW %d", n[1], n[2])
		end)
	end

	BlockSync.PlacementRejected:Connect(function(bayModel, _, reason)
		if bayModel ~= bay then
			return
		end
		flashText, flashUntil = reason, os.clock() + 2.5
	end)

	----------------------------------------------------------------
	-- The crate SEATING is the only thing that advances the route and the only thing that
	-- starts a cooldown -- which is why this listens to CratePlaced and not CellsChanged.
	--
	-- CellsChanged fires the moment the operator's cube moves on the real table, which is
	-- about five seconds before the arm has carried the crate anywhere, and it fires for cells
	-- the placement guard went on to REFUSE. Driving the bay off it marked a cell the player
	-- could not actually stand on as safe, and started the cooldown on the cell under their
	-- feet while the new one was still in the air.
	--
	-- While the crate is in flight there is no safe cell to switch to, and blockKey
	-- deliberately keeps its old value through that gap -- that is what keeps the ground under
	-- the player safe until the new cell is genuinely ready.
	----------------------------------------------------------------
	BlockSync.CratePlaced:Connect(function(bayModel, cell)
		if bayModel ~= bay or not running then
			return
		end
		if (cell.level or 1) < info.level then
			return
		end
		local landed = keyOf(cell.col, cell.row)
		if landed == blockKey then
			return
		end

		if blockKey then
			cooling[blockKey] = os.clock() + Config.LaserCooldownSeconds
			lastVacated = blockKey
		end
		blockKey = landed

		local n = nextCell()
		if n and landed == keyOf(n[1], n[2]) then
			step += 1
			emitTarget()
		end
	end)

	----------------------------------------------------------------
	-- HUD
	----------------------------------------------------------------
	local function pushObjective()
		local p = {title = string.format("BAY %d  -  LASER WALK", i)}
		if state.solved then
			p.task = "CLEARED"
			p.hint = "The grid is down -- walk out."
			p.tone = "ok"
		elseif not running then
			p.task = "STEP ONTO THE GRID"
			p.hint = "Every cell is live. The crate is the only safe ground."
			p.tone = "danger"
		else
			local n = nextCell()
			if n then
				p.task = string.format("%s  ->  COL %d, ROW %d",
					blockReq(info.level), n[1], n[2])
				p.hint = string.format("Step %d of %d. Only that cell will take the crate.",
					step + 1, #route)
				p.tone = (step == 0) and "danger" or "warn"
			else
				p.task = "STAND ON THE LAST CELL"
				p.hint = "Route complete -- step onto the crate's cell to kill the grid."
				p.tone = "warn"
			end

			-- The countdown is specifically the cell the crate JUST left, because that is the
			-- one the player is standing on. Showing whichever cooldown expires soonest looked
			-- right until two overlapped, and then it counted down a cell already behind them
			-- -- reading 0.3s while the ground underfoot actually had a full 6s left.
			local at = lastVacated and cooling[lastVacated] or nil
			if at then
				local left = math.max(0, at - os.clock())
				-- Name the cell. "CELL GOES LIVE IN" with two cells cooling told you a number
				-- but not which ground it belonged to.
				local c, r = lastVacated:match("(%d+),(%d+)")
				p.timerLabel = c and ("COL %s, ROW %s GOES LIVE IN"):format(c, r)
					or "CELL GOES LIVE IN"
				p.timer = left
				p.timerTone = (left <= Config.LaserRearmWarnSeconds) and "danger" or "warn"
			end
		end

		if os.clock() < flashUntil then
			p.flash = flashText
		end
		publishObjective(i, p, CELL)
	end

	----------------------------------------------------------------
	-- Run loop
	----------------------------------------------------------------
	local function inCell(pos, col, row)
		local c = cellCenter(i, col, row)
		return math.abs(pos.X - c.X) <= CELL / 2 and math.abs(pos.Z - c.Z) <= CELL / 2
	end

	task.spawn(function()
		while folder.Parent do
			local occupants = occupantsOf(i, ARM_PAD)
			local now = os.clock()

			if state.solved then
				-- cleared for good; grid stays down
			elseif not running then
				if #occupants > 0 then
					armRun()
				end
			elseif #occupants == 0 then
				-- The bay emptied unsolved, which in practice means the player died on the
				-- grid. By design that regenerates the route and the operator has to carry the
				-- cube back to the new first cell -- so the HUD has to be loud about it.
				disarm()
			end

			if running and not state.solved then
				for k, at in pairs(cooling) do
					if now >= at then
						cooling[k] = nil
					end
				end

				for k, cell in pairs(cells) do
					if k == blockKey then
						setCellState(cell, SAFE)
					elseif cooling[k] then
						local left = cooling[k] - now
						local rate = (left <= Config.LaserRearmWarnSeconds) and 14 or 4
						setCellState(cell, COOLING, math.sin(now * rate) > 0)
						-- tenths under the warning threshold, so the last two seconds read as
						-- urgent rather than as a 2 that sits there
						if cell.count then
							cell.count.Text = (left <= Config.LaserRearmWarnSeconds)
								and ("%.1f"):format(math.max(0, left))
								or tostring(math.ceil(left))
							cell.count.TextColor3 = (left <= Config.LaserRearmWarnSeconds)
								and Color3.fromRGB(70, 10, 10) or Color3.fromRGB(20, 14, 6)
						end
					else
						setCellState(cell, LIVE)
					end
				end

				-- solved by standing on the final cell of the route, not merely by the crate
				-- arriving there -- the player has to actually make the last step
				if route and step >= #route and blockKey then
					local last = route[#route]
					for _, o in ipairs(occupants) do
						if inCell(o.position, last[1], last[2]) then
							state.setSolved(true)
							break
						end
					end
				end
			end

			pushObjective()
			task.wait(0.1)
		end
	end)

	function state.onSolved()
		-- staggered power-down, so the grid dies in a sweep rather than all at once
		task.spawn(function()
			local idx = 0
			for _, cell in pairs(cells) do
				setCellState(cell, SAFE)
				cell.pad.Transparency = 1
				idx += 1
				if idx % 3 == 0 then
					task.wait(0.03)
				end
			end
		end)
		emitTarget()
	end

	function state.reset()
		disarm()
		for _, cell in pairs(cells) do
			setCellState(cell, LIVE)
		end
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
	-- DARK ROOM. A search, not a traverse -- the only bay where the obstacle is not knowing
	-- where anything is.
	--
	-- The cube is a TOKEN, like the laser walk: a block on the operator's mat hangs a LANTERN
	-- from the ceiling above that cell. Nothing is carried in and nothing is stood on. What the
	-- operator is really doing is aiming a torch, one cell at a time, while the runner searches
	-- the pool of light underneath it.
	--
	-- Ten screws lie on the floor and are INVISIBLE unless their cell is lit. That gate is the
	-- whole bay: you cannot sweep the floor blind, so finding them is a conversation -- "light
	-- column 2" -- rather than a walk. With all ten in, a power box on the side wall at head
	-- height comes live, and driving its screws unlocks the room and brings the lights up.
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	if bay then
		bay:SetAttribute("VirtualCrates", true)
	end

	local z0 = bayZStart(i)
	local W, D = Config.BayWidth, Config.BayDepth
	local CEIL_Y = 14          -- low enough to read as a room, below the gantry rails at 18
	local SCREW_COUNT = 10

	local DARK = Color3.fromRGB(26, 26, 32)
	local WARM = Color3.fromRGB(255, 206, 128)
	local STEEL = Color3.fromRGB(198, 202, 212)

	----------------------------------------------------------------
	-- The room. Sealed on four sides and roofed, because "dark" has to come from being shut
	-- in rather than from a tinted box you can still see the warehouse through.
	----------------------------------------------------------------
	for _, side in ipairs({{"Left", 0}, {"Right", W}}) do
		newPart("DarkWall" .. side[1], Vector3.new(1, CEIL_Y, D),
			Vector3.new(side[2], CEIL_Y / 2, z0 + D / 2), DARK,
			Enum.Material.DiamondPlate, folder, {CanCollide = true})
	end
	newPart("DarkWallFar", Vector3.new(W + 2, CEIL_Y, 1),
		Vector3.new(W / 2, CEIL_Y / 2, z0 + D), DARK, Enum.Material.DiamondPlate, folder,
		{CanCollide = true})
	newPart("DarkCeiling", Vector3.new(W + 2, 1, D),
		Vector3.new(W / 2, CEIL_Y, z0 + D / 2), DARK, Enum.Material.DiamondPlate, folder,
		{CanCollide = true})

	-- The door you came in by. It drops behind you, which is what makes this a locked room.
	local GATE_H = 14
	local gate = newPart("DarkGate", Vector3.new(W, GATE_H, 1),
		Vector3.new(W / 2, -GATE_H / 2, z0), Color3.fromRGB(58, 56, 52),
		Enum.Material.DiamondPlate, folder, {CanCollide = true})

	-- The way out, in the far wall. Stays shut until the power box is driven.
	local exitDoor = newPart("DarkExit", Vector3.new(CELL * 1.5, 9, 1.2),
		Vector3.new(W / 2, 4.5, z0 + D), Color3.fromRGB(44, 48, 56),
		Enum.Material.Metal, folder, {CanCollide = true})
	local exitGlow = newPart("DarkExitEdge", Vector3.new(CELL * 1.5 + 0.4, 0.3, 1.5),
		Vector3.new(W / 2, 9.2, z0 + D), Color3.fromRGB(70, 74, 84),
		Enum.Material.Neon, folder, {CanQuery = false})

	----------------------------------------------------------------
	-- Wall sconces, not ceiling lanterns.
	--
	-- A block lights the sconce for its cell, and the throw is WIDE on purpose: one lamp
	-- bleeds across its neighbours, so two or three blocks wash most of the room rather than
	-- picking out twelve separate squares. Light coming in sideways also rakes across the
	-- floor, which is what makes a screw lying on it catch the eye -- a lamp directly overhead
	-- lights the floor flatly and hides them.
	--
	-- HOTSPOTS. Three cells are wired to a double fixture and throw much further. They are
	-- visible even unlit, by the neon trim ring, so the operator can see them from the
	-- spectator view and choose: a block on a hotspot lights most of the room, a block
	-- anywhere else still helps but less. That is the whole placement decision in this bay.
	local SCONCE_Y = 5.2
	local hotspots = {}
	do
		local all = {}
		for col = 0, Config.BayCols - 1 do
			for row = 0, Config.BayRows - 1 do
				table.insert(all, col .. "," .. row)
			end
		end
		for n = #all, 2, -1 do
			local j = math.random(n)
			all[n], all[j] = all[j], all[n]
		end
		for n = 1, 3 do
			hotspots[all[n]] = true
		end
	end

	local lamps = {}
	for col = 0, Config.BayCols - 1 do
		for row = 0, Config.BayRows - 1 do
			local key = col .. "," .. row
			local hot = hotspots[key] == true
			local c = cellCenter(i, col, row)
			-- nearest side wall, nudged along it so the two columns sharing a wall do not
			-- land on top of each other
			local onLeft = (col < Config.BayCols / 2)
			local x = onLeft and 0.75 or (W - 0.75)
			local nudge = (col == 0 or col == Config.BayCols - 1) and -1.9 or 1.9
			local z = c.Z + nudge
			local inward = onLeft and 1 or -1

			local body = newPart("Sconce", Vector3.new(0.5, hot and 1.8 or 1.2, hot and 2.4 or 1.5),
				Vector3.new(x, SCONCE_Y, z), Color3.fromRGB(34, 34, 40),
				Enum.Material.Metal, folder, {CanQuery = false})
			-- the trim is emissive so a hotspot is readable in a pitch-dark room
			local trim = newPart("SconceTrim",
				Vector3.new(0.18, (hot and 1.8 or 1.2) + 0.3, (hot and 2.4 or 1.5) + 0.3),
				Vector3.new(x + inward * 0.3, SCONCE_Y, z),
				hot and Color3.fromRGB(120, 80, 20) or Color3.fromRGB(30, 30, 38),
				Enum.Material.Neon, folder, {CanQuery = false})
			local glass = newPart("SconceGlass", Vector3.new(0.22, hot and 1.3 or 0.9, hot and 1.8 or 1.1),
				Vector3.new(x + inward * 0.36, SCONCE_Y, z), WARM,
				Enum.Material.Neon, folder, {Transparency = 1, CanQuery = false})

			-- Which cell is this lamp? Six fittings a wall and no way to tell them apart was
			-- the actual problem with the lighting UI -- "light column two" is useless if the
			-- operator cannot find column two's lamp. The number is painted on the fitting,
			-- facing into the room.
			local tag = Instance.new("SurfaceGui")
			tag.Face = onLeft and Enum.NormalId.Right or Enum.NormalId.Left
			tag.LightInfluence = 0
			tag.PixelsPerStud = 40
			tag.Adornee = body
			tag.Parent = body
			local tagText = Instance.new("TextLabel")
			tagText.Size = UDim2.new(1, 0, 1, 0)
			tagText.BackgroundTransparency = 1
			tagText.Font = Enum.Font.GothamBold
			tagText.TextScaled = true
			tagText.TextColor3 = hot and Color3.fromRGB(255, 200, 110)
				or Color3.fromRGB(150, 158, 175)
			tagText.TextStrokeTransparency = 0.3
			tagText.Text = string.format("%d,%d", col, row)
			tagText.Parent = tag

			local light = Instance.new("SpotLight")
			light.Color = WARM
			light.Angle = 150
			light.Face = onLeft and Enum.NormalId.Right or Enum.NormalId.Left
			light.Range = hot and (CELL * 3.6) or (CELL * 1.8)
			light.Brightness = 0
			light.Enabled = false
			light.Parent = glass

			lamps[key] = {body = body, trim = trim, glass = glass, light = light,
				tag = tagText, hot = hot, on = false}
		end
	end

	local function setLamp(col, row, on)
		local l = lamps[col .. "," .. row]
		if not l or l.on == on then
			return
		end
		l.on = on
		l.glass.Transparency = on and 0 or 1
		l.light.Enabled = on
		l.light.Brightness = on and (l.hot and 5.0 or 2.6) or 0
		l.trim.Color = on and (l.hot and Color3.fromRGB(255, 190, 90) or Color3.fromRGB(190, 150, 90))
			or (l.hot and Color3.fromRGB(120, 80, 20) or Color3.fromRGB(30, 30, 38))
		if l.tag then
			l.tag.TextColor3 = on and Color3.fromRGB(255, 240, 210)
				or (l.hot and Color3.fromRGB(255, 200, 110) or Color3.fromRGB(150, 158, 175))
		end
	end

	-- How far a lamp REVEALS, in cells.
	--
	-- Tuned down hard: at a 2-cell hotspot reach a single block in a corner lit nine of the
	-- twelve cells and showed 8 of the 10 screws, which is the whole bay solved by placing one
	-- cube anywhere. An ordinary lamp now pools over its own cell and a hotspot washes the ring
	-- around it, so the choice the operator makes is worth something: roughly one screw for a
	-- plain cell against four or five for an amber one.
	local function litRadiusCells(l)
		return l.hot and 1 or 0
	end

	local function isLit(col, row)
		for key, l in pairs(lamps) do
			if l.on then
				local lc, lr = key:match("(%d+),(%d+)")
				lc, lr = tonumber(lc), tonumber(lr)
				local reach = litRadiusCells(l)
				if math.abs(lc - col) <= reach and math.abs(lr - row) <= reach then
					return true
				end
			end
		end
		return false
	end

	----------------------------------------------------------------
	-- The ceiling lights. Dead until the power box is driven -- then the wall lamps go out and
	-- these come up, which is the room going back to normal and the way on opening.
	----------------------------------------------------------------
	local ceilingLights = {}
	for n = 0, 2 do
		local z = z0 + D * (0.2 + n * 0.3)
		local panel = newPart("CeilingPanel", Vector3.new(W * 0.55, 0.35, 2.2),
			Vector3.new(W / 2, CEIL_Y - 0.8, z), Color3.fromRGB(70, 72, 80),
			Enum.Material.SmoothPlastic, folder, {CanQuery = false})
		local lamp = Instance.new("PointLight")
		lamp.Color = Color3.fromRGB(235, 242, 255)
		lamp.Range = CELL * 4.5
		lamp.Brightness = 0
		lamp.Enabled = false
		lamp.Parent = panel
		table.insert(ceilingLights, {panel = panel, light = lamp})
	end

	local function setCeiling(on)
		for _, c in ipairs(ceilingLights) do
			c.light.Enabled = on
			c.light.Brightness = on and 3.0 or 0
			c.panel.Material = on and Enum.Material.Neon or Enum.Material.SmoothPlastic
			c.panel.Color = on and Color3.fromRGB(240, 246, 255) or Color3.fromRGB(70, 72, 80)
		end
	end

	----------------------------------------------------------------
	-- The screws. Scattered, and invisible until their cell is lit.
	----------------------------------------------------------------
	local screws = {}
	local found = 0
	do
		-- Spread over the twelve cells so no single lantern reveals half of them, and jittered
		-- within each so a lit cell still has to be looked at rather than merely entered.
		local slots = {}
		for col = 0, Config.BayCols - 1 do
			for row = 0, Config.BayRows - 1 do
				table.insert(slots, {col, row})
			end
		end
		for n = #slots, 2, -1 do
			local j = math.random(n)
			slots[n], slots[j] = slots[j], slots[n]
		end
		for n = 1, SCREW_COUNT do
			local slot = slots[((n - 1) % #slots) + 1]
			local c = cellCenter(i, slot[1], slot[2])
			local jx = (math.random() - 0.5) * (CELL - 2.5)
			local jz = (math.random() - 0.5) * (CELL - 2.5)
			local screw = newPart("Screw", Vector3.new(0.45, 1.1, 0.45),
				Vector3.new(c.X + jx, 0.55, c.Z + jz), STEEL, Enum.Material.Metal, folder,
				{Transparency = 1, CanQuery = false, Shape = Enum.PartType.Cylinder})
			screw.CFrame = CFrame.new(screw.Position) * CFrame.Angles(0, 0, math.rad(90))
			table.insert(screws, {part = screw, col = slot[1], row = slot[2], taken = false})
		end
	end

	----------------------------------------------------------------
	-- The power box. Dead until every screw is in, then it is the way out.
	----------------------------------------------------------------
	local boxZ = z0 + D * 0.5
	local box = newPart("PowerBox", Vector3.new(0.6, 3.4, 2.6),
		Vector3.new(W - 1.2, 4.6, boxZ), Color3.fromRGB(38, 38, 44),
		Enum.Material.DiamondPlate, folder, {CanCollide = false})
	local boxLamp = newPart("PowerBoxLamp", Vector3.new(0.3, 0.4, 2.0),
		Vector3.new(W - 1.6, 6.1, boxZ), Color3.fromRGB(70, 20, 20),
		Enum.Material.Neon, folder, {CanQuery = false})
	local driver = newPart("Screwdriver", Vector3.new(0.3, 1.6, 0.3),
		Vector3.new(W - 2.0, 4.6, boxZ), Color3.fromRGB(220, 180, 60),
		Enum.Material.Metal, folder, {Transparency = 1, CanQuery = false})

	local boxLabel = addLabel(folder, "POWER BOX  -  SEALED",
		Vector3.new(W - 2.2, 7.6, boxZ), Color3.fromRGB(150, 120, 120))

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Drive the screws"
	prompt.ObjectText = "Power Box"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 2.5
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = box

	----------------------------------------------------------------
	-- Lighting. Saved and restored, because Lighting is a GLOBAL service: leave it dim and
	-- every other bay is dim too, including whatever the overseer is looking at.
	----------------------------------------------------------------
	-- THE BASELINE IS NOT "WHATEVER LIGHTING LOOKED LIKE WHEN THIS BUILDER RAN".
	--
	-- It used to be, and that is a trap: a bay is reset by REBUILDING it, so resetting bay 4
	-- while the room was dark re-ran this line with Brightness already 0 and Ambient already
	-- black -- and from then on "restore" restored to pitch black, for every bay, forever.
	-- The real baseline is a property of the place, not of the moment, so it is stamped onto
	-- Lighting as attributes by build/backdrop_lighting.lua and read back here. Falling back
	-- to the live values keeps this working in a place where that script has not been run.
	local saved = {
		Ambient = Lighting:GetAttribute("BaselineAmbient") or Lighting.Ambient,
		OutdoorAmbient = Lighting:GetAttribute("BaselineOutdoorAmbient") or Lighting.OutdoorAmbient,
		Brightness = Lighting:GetAttribute("BaselineBrightness") or Lighting.Brightness,
	}
	local dark = false
	local function setDark(on)
		if dark == on then
			return
		end
		dark = on
		if on then
			-- genuinely dark: at 0.15 brightness with a lifted ambient you could still read
			-- the floor, which made the lamps cosmetic
			Lighting.Ambient = Color3.fromRGB(1, 1, 2)
			Lighting.OutdoorAmbient = Color3.fromRGB(1, 1, 3)
			Lighting.Brightness = 0
		else
			Lighting.Ambient = saved.Ambient
			Lighting.OutdoorAmbient = saved.OutdoorAmbient
			Lighting.Brightness = saved.Brightness
		end
	end

	----------------------------------------------------------------
	-- Which cells are lit follows the operator's blocks.
	----------------------------------------------------------------
	local litCells = {}
	BlockSync.CellsChanged:Connect(function(bayModel, cellsList)
		if not folder.Parent or bayModel ~= folder.Parent then
			return
		end
		local now = {}
		for _, c in ipairs(cellsList) do
			now[c.col .. "," .. c.row] = true
		end
		litCells = now
		for col = 0, Config.BayCols - 1 do
			for row = 0, Config.BayRows - 1 do
				setLamp(col, row, now[col .. "," .. row] == true)
			end
		end
	end)

	----------------------------------------------------------------
	-- Picking screws up. Only in the light -- otherwise you would sweep the floor blind and
	-- the lanterns would be decoration.
	----------------------------------------------------------------
	local function collect(entry)
		if entry.taken or not isLit(entry.col, entry.row) then
			return
		end
		entry.taken = true
		found += 1
		entry.part.Transparency = 1
		entry.part.CanTouch = false
		local pop = newPart("ScrewPop", Vector3.new(0.6, 0.6, 0.6), entry.part.Position,
			WARM, Enum.Material.Neon, folder,
			{CanQuery = false, Shape = Enum.PartType.Ball})
		TweenService:Create(pop, TweenInfo.new(0.35), {
			Size = Vector3.new(3, 3, 3),
			Transparency = 1,
		}):Play()
		Debris:AddItem(pop, 0.5)
	end

	for _, entry in ipairs(screws) do
		entry.part.Touched:Connect(function(hit)
			local ch = characterFrom(hit)
			if ch and not isGhost(ch) then
				collect(entry)
			end
		end)
	end

	----------------------------------------------------------------
	-- Driving the screws home.
	----------------------------------------------------------------
	local opened = false
	local function openRoom()
		if opened then
			return
		end
		opened = true
		prompt.Enabled = false

		task.spawn(function()
			-- the screwdriver turns, then the room comes back
			driver.Transparency = 0
			local spin = 0
			local t0 = os.clock()
			while os.clock() - t0 < 1.2 and folder.Parent do
				spin += 0.5
				driver.CFrame = CFrame.new(driver.Position) * CFrame.Angles(0, spin, 0)
				task.wait(0.03)
			end
			driver.Transparency = 1
			-- the wall lamps die and the ceiling comes up: the room going back to normal
			for col = 0, Config.BayCols - 1 do
				for row = 0, Config.BayRows - 1 do
					setLamp(col, row, false)
				end
			end
			setCeiling(true)
			setDark(false)
			boxLamp.Color = Color3.fromRGB(120, 240, 150)
			exitGlow.Color = Color3.fromRGB(120, 240, 150)
			boxLabel.Text = "POWER BOX  -  ON"
			boxLabel.TextColor3 = Color3.fromRGB(140, 255, 170)
			TweenService:Create(exitDoor, TweenInfo.new(1.0, Enum.EasingStyle.Quad), {
				CFrame = CFrame.new(exitDoor.Position.X, -5, exitDoor.Position.Z),
			}):Play()
			task.wait(1.0)
			exitDoor.CanCollide = false
			state.setSolved(true)
		end)
	end

	prompt.Triggered:Connect(function(player)
		local ch = player.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 or isGhost(ch) or found < SCREW_COUNT then
			return
		end
		openRoom()
	end)

	----------------------------------------------------------------
	-- Run loop
	----------------------------------------------------------------
	local running = false
	local function setRunning(on)
		if running == on then
			return
		end
		running = on
		TweenService:Create(gate, TweenInfo.new(0.5), {
			CFrame = CFrame.new(gate.Position.X,
				on and GATE_H / 2 or -GATE_H / 2, gate.Position.Z),
		}):Play()
		setDark(on)
	end

	task.spawn(function()
		while folder.Parent do
			local occupants = occupantsOf(i, 0)
			setRunning(#occupants > 0 and not state.solved)

			for _, entry in ipairs(screws) do
				if not entry.taken then
					entry.part.Transparency = isLit(entry.col, entry.row) and 0 or 1
				end
			end

			local ready = (found >= SCREW_COUNT)
			prompt.Enabled = ready and not opened
			if opened then
				-- left as the open-room presentation
			elseif ready then
				boxLamp.Color = Color3.fromRGB(240, 200, 60)
				boxLabel.Text = "POWER BOX  -  HOLD E"
				boxLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
			else
				boxLamp.Color = Color3.fromRGB(70, 20, 20)
				boxLabel.Text = string.format("POWER BOX  -  %d/%d SCREWS", found, SCREW_COUNT)
				boxLabel.TextColor3 = Color3.fromRGB(170, 130, 130)
			end

			local p = nil
			if running or state.solved then
				p = {title = "BAY 4  -  DARK ROOM"}
				if state.solved then
					p.task = "CLEARED"
					p.hint = "The lights are on and the door is open."
					p.tone = "ok"
				elseif ready then
					p.task = "POWER BOX  -  DRIVE THE SCREWS"
					p.hint = "Right-hand wall, middle of the room. Hold E."
					p.tone = "warn"
				else
					p.task = string.format("FIND THE SCREWS  -  %d / %d", found, SCREW_COUNT)
					p.hint = "Call out a cell. A block lights that wall lamp, and a screw only"
						.. " shows in the light. The amber fittings throw furthest."
					p.tone = "danger"
				end
				local litCount = 0
				for _ in pairs(litCells) do
					litCount += 1
				end
				p.steps = {
					string.format("%s  %d / %d screws",
						ready and "[x]" or "[ ]", found, SCREW_COUNT),
					string.format("%s  power box  -  %s",
						opened and "[x]" or (ready and "[ ]" or "[-]"),
						opened and "driven" or (ready and "ready" or "sealed")),
				}
				local hotLit = 0
				for key in pairs(litCells) do
					if hotspots[key] then
						hotLit += 1
					end
				end
				p.note = string.format(
					"%d lamp%s lit, %d on a hotspot. The amber fittings light far more than the rest.",
					litCount, (litCount == 1) and "" or "s", hotLit)
			end
			publishObjective(i, p, CELL)
			task.wait(0.2)
		end
		-- never leave the world dark because the bay was torn down mid-run
		setDark(false)
	end)

	function state.onSolved()
		setDark(false)
		prompt.Enabled = false
	end

	function state.reset()
		setDark(false)
		setCeiling(false)
		opened = false
		found = 0
		driver.Transparency = 1
		for _, entry in ipairs(screws) do
			entry.taken = false
			entry.part.CanTouch = true
			entry.part.Transparency = 1
		end
	end
end
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
	folder:SetAttribute("Level", info.level)

	local c = bayCenter(i)
	-- A bay may name its own banner -- an action bay's requirement is not "colour x level" and
	-- the default used to be hard-coded to bay 1's levers, which was wrong for every other
	-- action bay. The default still describes a placement bay, which is most of them.
	state.banner = info.banner
		or string.format("%s  -  %s", info.obstacle:upper(), blockReq(info.level))
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
	-- Colour is deliberately not checked: any block satisfies a cell. The level test stays,
	-- because that is a cube COUNT -- a level-2 cell still wants two cubes stacked.
	for _, sc in ipairs(info.solveCells) do
		local c = byKey[sc[1] .. "," .. sc[2]]
		if not c then return false end
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
	if ownsItsSolve(state.info) then
		return
	end

	-- A solved placement bay LATCHES. With the real rig, advancing requires player 2 to sweep
	-- the physical mat clear and re-place for the next bay -- there are only two cubes of each
	-- colour, so the cubes holding one bay open are the same ones the next bay needs. Without
	-- this latch that sweep re-arms every bay behind player 1: the void opens back up under
	-- someone walking out of a bay they already cleared.
	--
	-- Measured before the latch went in: 2 crates -> "VOID - CLEARED", then the mat sweep ->
	-- 0 crates -> "VOID - RED x1" again, 5.5 s later.
	--
	-- Switch-mode bays were already immune, which is why only this branch needs it. The R
	-- hotkey below is still the way to genuinely un-solve a bay.
	if state.solved then
		return
	end

	state.setSolved(checkSolved(state.info, cellsList))
end)

-- A bay is reset by REBUILDING it, not by asking it to tidy up after itself.
--
-- The old reset called setSolved(false) plus an optional per-obstacle state.reset(), and
-- carried a standing caveat: obstacles that present "solved" as a one-shot tween (the laser
-- grid fading out) never animated back, so their loops resumed while the visual stayed
-- cleared. Only the saw bay rebuilt properly. buildBay already destroys the Obstacle folder
-- and runs the builder from scratch, and every run loop in this file is `while folder.Parent
-- do`, so destroying the folder terminates all of them cleanly. Rebuilding is therefore a
-- genuine fresh state for every bay, and the caveat is gone rather than documented.
--
-- Crates are a separate concern and belong to BlockSync: a rebuilt bay that kept the previous
-- run's crates would also keep the diff state saying they are there, so re-placing the same
-- cube would be a no-op.
local function resetBay(i)
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	if bay then
		BlockSync.clearBay(bay)
	end
	local st = buildBay(i)
	-- tell the crate sources to forget this bay, or the next edit re-delivers what was here
	RunControl.notifyBayReset(i)
	return st
end

RunControl.rebuildBay = resetBay

-- Wipe the whole course. Used when the crate source changes: solo and live disagree about who
-- owns the crates and what the arm is doing, so nothing may survive the switch.
function RunControl.rebuildAll()
	for n = 1, Config.NumBays do
		resetBay(n)
		task.wait()
	end
end
RunControl.bayState = function(i)
	local bay = Workspace.Warehouse:FindFirstChild(string.format("Bay%02d", i))
	return bay and states[bay]
end
RunControl.markReady()

local DebugHotkey = Remotes:WaitForChild("DebugHotkey")
DebugHotkey.OnServerEvent:Connect(function(_, key)
	if key ~= "R" then
		return
	end
	for i = 1, Config.NumBays do
		resetBay(i)
		task.wait()
	end
	print("[HazardManager] all bays rebuilt from scratch")
end)

print("[HazardManager] one obstacle per bay built for all " .. Config.NumBays .. " bays")
