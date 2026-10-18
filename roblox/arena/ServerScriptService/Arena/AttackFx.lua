--!strict
-- What a slam, a sweep and a fire breath look like - and what they hit.
--
-- WHAT YOU SEE IS WHAT HITS (hard rule 3). Every hit volume in this file is the drawn thing: the
-- shockwave ring is tested at the radius the ring has actually grown to on that frame, and the
-- fire cone is tested at the FIRE_RANGE and FIRE_HALF_ANGLE the particles are emitted into. There
-- is no generous hidden radius anywhere. If you widen a cone, widen the particles with it.
--
-- NOTHING HERE MOVES THE DRAGON. These are effects *around* the dragon, parented to the world or
-- to the head, never offsets applied to the rig. The dragon's position is DragonArm's business and
-- comes only from arm.points.
--
--   local fx = AttackFx.new(workspace, arena, dragon)
--   fx.onHit = function(player, kind) ... end
--   detect.onSlam = function(tip, speed) fx:slam(tip, speed) end

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Remotes = require(ReplicatedStorage.Arena.Remotes)
local Mapping = require(script.Parent.Parent.Mapping)

local AttackFx = {}
AttackFx.__index = AttackFx

local C = Theme.Color

local SLAM_FLASH_S = 0.08
local SLAM_RING_S = 0.45
local SWEEP_TRAIL_S = 0.3

function AttackFx.new(parent: Instance, arena: any, dragon: any)
	local self = setmetatable({}, AttackFx)
	self.parent = parent
	self.arena = arena
	self.dragon = dragon
	self.rng = Random.new()
	self.lastHit = {} :: { [Player]: number }     -- HIT_GRACE_S debounce, per player
	self.onHit = nil :: ((player: Player, kind: string) -> ())?
	self.fireParts = nil :: any
	self.sweepParts = nil :: any
	self.lastScorch = 0
	return self
end

-- Alive players with a character on the floor. Everything that deals damage goes through this, so
-- a spectator or a respawning player is never hit.
function AttackFx.targets(self): { { player: Player, root: BasePart } }
	local out = {}
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			table.insert(out, { player = player, root = root :: BasePart })
		end
	end
	return out
end

-- A player cannot be hit twice inside HIT_GRACE_S. Without it a sweep running at 30 frames a
-- second registers thirty hits on the same player, and a shockwave and a sweep landing together
-- double up.
function AttackFx.canHit(self, player: Player): boolean
	local last = self.lastHit[player]
	if last and os.clock() - last < ArenaConfig.HIT_GRACE_S then
		return false
	end
	self.lastHit[player] = os.clock()
	return true
end

function AttackFx.hit(self, player: Player, kind: string, knockback: Vector3?)
	if not self:canHit(player) then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and knockback then
		root.AssemblyLinearVelocity = knockback
	end
	if self.onHit then
		local ok, err = pcall(self.onHit, player, kind)
		if not ok then
			warn("[AttackFx] onHit errored: " .. tostring(err))
		end
	end
end

local function fxPart(parent: Instance, name: string, color: Color3, material: Enum.Material,
	size: Vector3, cf: CFrame): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

-- ---------------------------------------------------------------------------------------------
-- Slam
-- ---------------------------------------------------------------------------------------------

function AttackFx.slam(self, tipMm: any, speed: number)
	local at = Mapping.point(tipMm)
	local floorY = self.arena:floorY()
	local ground = Vector3.new(at.X, floorY + 0.1, at.Z)

	self:slamFlash(ground)
	self:slamRing(ground)
	self:slamDebris(ground)
	self:slamBurst(ground)
	self:slamShake(ground)
	self.arena:addCrater(ground, ArenaConfig.SLAM_RADIUS * 0.22)
end

function AttackFx.slamFlash(self, ground: Vector3)
	local flash = fxPart(self.parent, "SlamFlash", C.WhiteHot, Enum.Material.Neon,
		Vector3.new(26, 0.4, 26), CFrame.new(ground) * CFrame.Angles(0, 0, math.pi / 2))
	flash.Shape = Enum.PartType.Cylinder
	Debris:AddItem(flash, SLAM_FLASH_S)
end

-- The ring grows from the head's width out to SLAM_RADIUS while fading. Kept low and thin on
-- purpose: it has to look like something a player can jump over, because it is.
--
-- IT IS BUILT AS AN ACTUAL RING, not a disc with a hole painted on. A flat cylinder was the
-- obvious thing and it is wrong here: the hazard is the travelling edge, so a filled disc draws a
-- danger area that is mostly safe. That breaks hard rule 3 in the direction players notice least
-- but trust least too - they learn the middle is survivable and stop believing the drawing.
-- RING_SEGMENTS chunks around the circumference give the same chunky Roblox look, and the hit test
-- below is then the same band the player can see.
local RING_SEGMENTS = 16
local RING_BAND = 5             -- studs either side of the edge; the chunks are this thick

function AttackFx.slamRing(self, ground: Vector3)
	local model = Instance.new("Model")
	model.Name = "Shockwave"
	model.Parent = self.parent

	local chunks = {}
	for k = 1, RING_SEGMENTS do
		local chunk = fxPart(model, "Arc" .. k, C.LavaHot, Enum.Material.Neon,
			Vector3.new(4, 0.8, RING_BAND), CFrame.new(ground))
		chunks[k] = chunk
	end

	task.spawn(function()
		local t0 = os.clock()
		local hitAlready = {} :: { [Player]: boolean }
		local startR, endR = 7, ArenaConfig.SLAM_RADIUS
		while model.Parent do
			local f = (os.clock() - t0) / SLAM_RING_S
			if f >= 1 then
				break
			end
			local r = startR + (endR - startR) * f
			-- Arc width grows with the radius so the ring stays closed as it expands, instead of
			-- opening into sixteen separate flying bricks.
			local arcWidth = (2 * math.pi * r) / RING_SEGMENTS * 1.08
			local colour = C.LavaHot:Lerp(C.Ember, f)
			for k, chunk in chunks do
				local a = (k / RING_SEGMENTS) * math.pi * 2
				chunk.Size = Vector3.new(arcWidth, 0.8, RING_BAND)
				chunk.CFrame = CFrame.new(ground + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
					* CFrame.Angles(0, -a, 0)
				chunk.Transparency = f * 0.9
				chunk.Color = colour
			end

			-- The leading edge is the hazard, and it is exactly the band drawn above. A player who
			-- was standing at the centre and has not moved is not hit: the ring has already passed
			-- them, which is what they can see.
			for _, t in self:targets() do
				if not hitAlready[t.player] then
					local flat = Vector3.new(t.root.Position.X, ground.Y, t.root.Position.Z)
					local d = (flat - ground).Magnitude
					if math.abs(d - r) <= RING_BAND then
						hitAlready[t.player] = true
						local push = flat - ground
						push = (push.Magnitude > 0.1 and push.Unit or Vector3.new(0, 0, 1))
							* ArenaConfig.SLAM_KNOCKBACK + Vector3.new(0, 40, 0)
						self:hit(t.player, "slam", push)
					end
				end
			end
			task.wait()
		end
		model:Destroy()
	end)
end

function AttackFx.slamDebris(self, ground: Vector3)
	for k = 1, self.rng:NextInteger(6, 10) do
		local size = self.rng:NextNumber(1.5, 4)
		local chunk = Instance.new("Part")
		chunk.Name = "Debris" .. k
		chunk.Size = Vector3.new(size, size * 0.8, size * 1.1)
		chunk.Color = C.Basalt
		chunk.Material = Enum.Material.Rock
		chunk.CanCollide = false
		chunk.CanQuery = false
		chunk.CastShadow = false
		chunk.CFrame = CFrame.new(ground + Vector3.new(
			self.rng:NextNumber(-8, 8), 1, self.rng:NextNumber(-8, 8)))
		chunk.AssemblyLinearVelocity = Vector3.new(
			self.rng:NextNumber(-40, 40), self.rng:NextNumber(40, 80), self.rng:NextNumber(-40, 40))
		chunk.Parent = self.parent
		Debris:AddItem(chunk, 2)
	end
end

-- One-off bursts use Emit(), never a Rate toggled on and off: an emitter left enabled for a frame
-- keeps spitting after the slam and eats the particle budget the fire needs.
function AttackFx.slamBurst(self, ground: Vector3)
	local host = fxPart(self.parent, "SlamBurst", C.Scorch, Enum.Material.Neon,
		Vector3.new(1, 1, 1), CFrame.new(ground))
	host.Transparency = 1

	local smoke = Instance.new("ParticleEmitter")
	smoke.Color = ColorSequence.new(C.Scorch)
	smoke.Size = NumberSequence.new(6, 18)
	smoke.Lifetime = NumberRange.new(0.8, 1.6)
	smoke.Speed = NumberRange.new(14, 30)
	smoke.SpreadAngle = Vector2.new(70, 70)
	smoke.Rate = 0
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Parent = host

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(C.LavaHot, C.Ember)
	sparks.Size = NumberSequence.new(1.1, 0.2)
	sparks.Lifetime = NumberRange.new(0.4, 0.9)
	sparks.Speed = NumberRange.new(40, 80)
	sparks.SpreadAngle = Vector2.new(60, 60)
	sparks.LightEmission = 1
	sparks.Rate = 0
	sparks.Parent = host

	smoke:Emit(26)
	sparks:Emit(34)
	Debris:AddItem(host, 2)
end

-- Camera shake is the one effect that touches the player's screen, and it is the dragon's doing,
-- not a player's. Debuff visuals never shake a player camera (style guide section 8): the players
-- caused those, so punishing their screens for landing one is backwards.
function AttackFx.slamShake(self, ground: Vector3)
	local maxDist = ArenaConfig.SLAM_RADIUS * 2
	for _, t in self:targets() do
		local d = (t.root.Position - ground).Magnitude
		if d < maxDist then
			local strength = 1 - d / maxDist
			Remotes.Shake:FireClient(t.player, strength, math.min(0.4, 0.2 + strength * 0.2))
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Sweep
-- ---------------------------------------------------------------------------------------------

function AttackFx.sweepStart(self)
	if self.sweepParts then
		return
	end
	local head = self.dragon.segments and self.dragon.segments[5]
	local neck = self.dragon.segments and self.dragon.segments[3]
	if not head then
		return
	end

	-- Trails only on the head and the upper neck (the performance budget). A trail per segment
	-- reads as a smear and costs five times as much.
	local trails = {}
	for _, seg in { head, neck } do
		if seg then
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, seg.spec.thickness * 0.4, 0)
			a0.Parent = seg.core
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -seg.spec.thickness * 0.4, 0)
			a1.Parent = seg.core

			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Color = ColorSequence.new(C.Ember)
			trail.Transparency = NumberSequence.new(0.2, 1)
			trail.Lifetime = SWEEP_TRAIL_S
			trail.LightEmission = 0.6
			trail.Parent = seg.core
			table.insert(trails, { trail = trail, a0 = a0, a1 = a1 })
		end
	end

	-- Sparks where the tip scrapes the ground.
	local sparkHost = fxPart(self.parent, "SweepSparks", C.LavaHot, Enum.Material.Neon,
		Vector3.new(1, 1, 1), CFrame.new(0, 0, 0))
	sparkHost.Transparency = 1
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(C.LavaHot, C.Ember)
	sparks.Size = NumberSequence.new(0.9, 0.1)
	sparks.Lifetime = NumberRange.new(0.3, 0.6)
	sparks.Speed = NumberRange.new(20, 50)
	sparks.SpreadAngle = Vector2.new(50, 50)
	sparks.LightEmission = 1
	sparks.Rate = 90
	sparks.Parent = sparkHost

	local dust = Instance.new("ParticleEmitter")
	dust.Color = ColorSequence.new(C.Scorch)
	dust.Size = NumberSequence.new(4, 12)
	dust.Lifetime = NumberRange.new(0.5, 1)
	dust.Speed = NumberRange.new(6, 16)
	dust.SpreadAngle = Vector2.new(60, 60)
	dust.Rate = 30
	dust.Transparency = NumberSequence.new(0.5, 1)
	dust.Parent = sparkHost

	self.sweepParts = { trails = trails, sparkHost = sparkHost }
end

function AttackFx.sweep(self, tipMm: any, dir: any)
	if not self.sweepParts then
		return
	end
	local at = Mapping.point(tipMm)
	self.sweepParts.sparkHost.CFrame = CFrame.new(at)

	-- The hit volume for a sweep is the dragon's own body, tested as overlap against the core
	-- segment parts - exactly the drawn dragon, with no extra reach bolted on.
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.dragon.model, self.arena.model }

	local knock = Vector3.new(dir.x, 0, dir.y)
	knock = (knock.Magnitude > 0.01 and knock.Unit or Vector3.new(0, 0, 1))
		* ArenaConfig.SWEEP_KNOCKBACK + Vector3.new(0, 50, 0)

	for _, hit in self.dragon:partsTouching(params) do
		local char = hit.Parent
		local player = char and Players:GetPlayerFromCharacter(char)
		if player then
			self:hit(player, "sweep", knock)
		end
	end
end

function AttackFx.sweepEnd(self)
	local parts = self.sweepParts
	if not parts then
		return
	end
	self.sweepParts = nil
	for _, t in parts.trails do
		t.trail.Enabled = false
		Debris:AddItem(t.trail, SWEEP_TRAIL_S + 0.1)
		Debris:AddItem(t.a0, SWEEP_TRAIL_S + 0.2)
		Debris:AddItem(t.a1, SWEEP_TRAIL_S + 0.2)
	end
	parts.sparkHost:Destroy()
end

-- ---------------------------------------------------------------------------------------------
-- Fire breath
-- ---------------------------------------------------------------------------------------------

function AttackFx.fireStart(self, frac: number)
	if self.fireParts then
		return
	end
	local mouth = self.dragon:mouthAttachment()
	if not mouth then
		return
	end

	local flame = Instance.new("ParticleEmitter")
	flame.Name = "Fire"
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, C.WhiteHot),
		ColorSequenceKeypoint.new(0.25, C.LavaHot),
		ColorSequenceKeypoint.new(0.55, C.Lava),
		ColorSequenceKeypoint.new(0.8, C.Ember),
		ColorSequenceKeypoint.new(1, C.Scorch),
	})
	flame.Size = NumberSequence.new(3, 20)
	flame.Lifetime = NumberRange.new(0.6, 0.9)
	flame.SpreadAngle = Vector2.new(ArenaConfig.FIRE_HALF_ANGLE, ArenaConfig.FIRE_HALF_ANGLE)
	flame.LightEmission = 1
	flame.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	flame.EmissionDirection = Enum.NormalId.Front
	flame.Parent = mouth

	local light = Instance.new("PointLight")
	light.Color = C.Lava
	light.Range = 30
	light.Brightness = 4
	light.Parent = mouth

	self.fireParts = { flame = flame, light = light, mouth = mouth }
	self:fire(frac)
end

-- Rate and speed grow with how far the jaw is open. This shows the arm's *current* state, which
-- hard rule 1 allows - it is feedback, not a wind-up, and it cannot predict anything.
function AttackFx.fire(self, frac: number)
	local parts = self.fireParts
	if not parts then
		return
	end
	parts.flame.Rate = 60 + 140 * frac
	parts.flame.Speed = NumberRange.new(60 + 20 * frac, 90 + 30 * frac)
	parts.light.Brightness = 3 + 3 * frac
	self:fireHits()
end

-- The hit volume is the drawn cone: FIRE_RANGE long, FIRE_HALF_ANGLE wide, measured from the mouth
-- along the head's forward axis - the same numbers the particles use. A raycast to each candidate
-- means rocks and platforms give real cover, so hiding behind the thing you can see works.
function AttackFx.fireHits(self)
	local parts = self.fireParts
	if not parts then
		return
	end
	local origin = parts.mouth.WorldPosition
	local forward = parts.mouth.WorldCFrame.LookVector
	local cosLimit = math.cos(math.rad(ArenaConfig.FIRE_HALF_ANGLE))

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { self.dragon.model }

	for _, t in self:targets() do
		local to = t.root.Position - origin
		local dist = to.Magnitude
		if dist <= ArenaConfig.FIRE_RANGE and dist > 0.1 then
			if to.Unit:Dot(forward) >= cosLimit then
				local result = workspace:Raycast(origin, to, rp)
				local blocked = result and not result.Instance:IsDescendantOf(t.root.Parent :: Instance)
				if not blocked then
					self:hit(t.player, "fire")
				end
			end
		end
	end

	-- Scorch where the cone meets the floor, throttled so a long roar does not blow the 20-mark
	-- budget in a second.
	if os.clock() - self.lastScorch > 0.4 then
		local down = workspace:Raycast(origin, forward * ArenaConfig.FIRE_RANGE, rp)
		if down then
			self.lastScorch = os.clock()
			self.arena:addScorch(down.Position, 10)
		end
	end
end

function AttackFx.fireEnd(self)
	local parts = self.fireParts
	if not parts then
		return
	end
	self.fireParts = nil
	parts.flame.Enabled = false
	Debris:AddItem(parts.flame, 1)
	parts.light:Destroy()
end

return AttackFx
