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

-- SAW: blade slot across row 1. A block dropped on the blade jams it, and that block is then
-- a safe step across the slot.
BUILDERS.Saw = function(i, folder, info, state)
	local c = cellCenter(i, 0, 1)
	local slotZ = c.Z

	newPart("SawSlot", Vector3.new(Config.BayWidth, 0.6, CELL - 1.5),
		Vector3.new(Config.BayWidth / 2, 0.05, slotZ), Color3.fromRGB(12, 12, 14),
		Enum.Material.Metal, folder)

	local blades = {}
	for k = 0, 3 do
		local blade = newPart("SawBlade" .. k, Vector3.new(0.4, 5, 5),
			Vector3.new(k * CELL + CELL / 2, 1.4, slotZ), Color3.fromRGB(205, 208, 214),
			Enum.Material.Metal, folder, {Shape = Enum.PartType.Cylinder})
		makeLethal(blade, state)
		table.insert(blades, blade)
	end

	task.spawn(function()
		while folder.Parent do
			if not state.solved then
				for _, b in ipairs(blades) do
					b.CFrame = b.CFrame * CFrame.Angles(0, 0, math.rad(22))
				end
			end
			task.wait(0.03)
		end
	end)

	function state.onSolved()
		-- jam: blades tilt crooked and sink into the slot
		for idx, b in ipairs(blades) do
			TweenService:Create(b, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
				CFrame = CFrame.new(b.Position - Vector3.new(0, 1.6, 0)) * CFrame.Angles(math.rad(12 * idx), 0, math.rad(70)),
			}):Play()
		end
	end
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

