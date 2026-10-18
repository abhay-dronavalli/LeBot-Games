--!strict
-- What the dragon looks like while a player's power-up is running on the real arm.
--
-- EFFECTS COME FROM SERVER STATE (hard rule 4). Every overlay here is driven by `state.effects` -
-- the list Python sends, with the name, intensity and remaining time it actually applied. Not by
-- the button press that asked for it. The server clamps every duration to its own caps
-- (bridge/effects.py LIMITS), so a request for 30 s of freeze becomes 3 s, and a HUD or an overlay
-- that believed the request would sit there showing 27 seconds of a debuff that already ended.
--
-- THE PLAYERS CAUSED THESE, SO THEY NEVER PUNISH THE PLAYERS' SCREENS. No player camera shake, no
-- fog over the player's view, no flipped player screen. plan.md's table describes those for the
-- obby, where the *player* is the one being messed with; in the arena the player is the one doing
-- the messing, so every effect lands on the dragon and on the operator's screen instead.
--
-- OVERLAYS FOLLOW THE DRAGON EXACTLY (hard rule 2). Each one is repositioned from the segment
-- pivots every frame, just as DragonArm's own decorations are. None of them tween the dragon.
-- Under `earthquake` especially: the real arm is already shaking and that shake arrives in
-- arm.points, so the visible wobble is real. Adding any on top would double it.
--
--   local fx = DragonEffects.new(dragon)
--   Bridge.onState(function(s) fx:update(s.effects) end)

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)

local DragonEffects = {}
DragonEffects.__index = DragonEffects

local C = Theme.Color
local FADE_S = 0.5           -- the overlay fades over the effect's last half second

function DragonEffects.new(dragon: any)
	local self = setmetatable({}, DragonEffects)
	self.dragon = dragon
	self.active = {} :: { [string]: any }    -- effect name -> its overlay parts
	self.folder = Instance.new("Folder")
	self.folder.Name = "DragonEffects"
	self.folder.Parent = dragon.model
	return self
end

local function overlayPart(parent: Instance, name: string, color: Color3, material: Enum.Material,
	size: Vector3): BasePart
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
	p.Parent = parent
	return p
end

-- ---------------------------------------------------------------------------------------------
-- One builder per effect. Each returns a table with a `parts` list and an optional `follow(alpha)`
-- that repositions it from the dragon each frame. `alpha` is 1 while the effect is running and
-- ramps to 0 over its last half second, so players see it ending rather than blinking out.
-- ---------------------------------------------------------------------------------------------

local Builders = {}

-- SHAKE: aqua arcs jumping between the joint rings, sparks off the plates. The wobble itself is
-- the real arm's, already in arm.points. Nothing here moves anything.
function Builders.earthquake(self)
	local arcs = {}
	for i = 1, math.max(#self.dragon.joints - 1, 0) do
		local arc = overlayPart(self.folder, "Arc" .. i, C.Shake, Enum.Material.Neon,
			Vector3.new(0.8, 0.8, 1))
		arc.Transparency = 0.2
		table.insert(arcs, arc)
	end
	local sparkHost = overlayPart(self.folder, "QuakeSparks", C.Shake, Enum.Material.Neon,
		Vector3.new(1, 1, 1))
	sparkHost.Transparency = 1
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(C.Shake)
	sparks.Size = NumberSequence.new(0.8, 0.1)
	sparks.Lifetime = NumberRange.new(0.2, 0.5)
	sparks.Speed = NumberRange.new(15, 40)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.LightEmission = 1
	sparks.Rate = 40
	sparks.Parent = sparkHost

	return {
		parts = { sparkHost, table.unpack(arcs) },
		follow = function(alpha: number)
			local pts = self.dragon.points
			for i, arc in arcs do
				if pts[i] and pts[i + 1] then
					local a, b = pts[i], pts[i + 1]
					-- The arc flickers between the rings rather than sitting solid, so it reads as
					-- electricity instead of a painted stripe.
					local jitter = math.sin(os.clock() * 37 + i) * 0.5 + 0.5
					arc.Size = Vector3.new(0.8, 0.8, (b - a).Magnitude)
					arc.CFrame = CFrame.lookAt((a + b) / 2, b)
					arc.Transparency = 1 - alpha * (0.35 + 0.45 * jitter)
				else
					arc.Transparency = 1
				end
			end
			local head = self.dragon:headCFrame()
			if head then
				sparkHost.CFrame = head
			end
			sparks.Rate = 40 * alpha
		end,
	}
end

-- SLOWED: an indigo ForceField sleeve around the neck with slow drifting particles. ForceField is
-- the one material that reads as "something is wrapped around this" without hiding the armour.
function Builders.molasses(self)
	local sleeves = {}
	for i = 2, 4 do
		local seg = self.dragon.segments[i]
		if seg then
			local t = seg.spec.thickness
			local sleeve = overlayPart(self.folder, "Sleeve" .. i, C.Slow,
				Enum.Material.ForceField, Vector3.new(t * 1.3, t * 1.2, seg.length * 1.02))
			sleeve.Transparency = 0.35
			table.insert(sleeves, { part = sleeve, seg = seg })
		end
	end
	local host = overlayPart(self.folder, "SlowMotes", C.Slow, Enum.Material.Neon, Vector3.new(1, 1, 1))
	host.Transparency = 1
	local motes = Instance.new("ParticleEmitter")
	motes.Color = ColorSequence.new(C.Slow)
	motes.Size = NumberSequence.new(1.6)
	motes.Lifetime = NumberRange.new(1.5, 2.5)
	motes.Speed = NumberRange.new(1, 4)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.LightEmission = 0.8
	motes.Rate = 18
	motes.Transparency = NumberSequence.new(0.3, 1)
	motes.Parent = host

	return {
		parts = { host, table.unpack((function()
			local list = {}
			for _, s in sleeves do table.insert(list, s.part) end
			return list
		end)()) },
		follow = function(alpha: number)
			for _, s in sleeves do
				s.part.CFrame = s.seg.model:GetPivot()
				s.part.Transparency = 1 - alpha * 0.65
			end
			local head = self.dragon:headCFrame()
			if head then
				host.CFrame = head
			end
			motes.Rate = 18 * alpha
		end,
	}
end

-- INVERTED: a magenta Neon overlay flickering on the segments a few times a second. Glitchy on
-- purpose - the operator's controls are mirrored, and the dragon should look like it is arguing
-- with itself.
function Builders.mirror(self)
	local shells = {}
	for i, seg in self.dragon.segments do
		local t = seg.spec.thickness
		local shell = overlayPart(self.folder, "Glitch" .. i, C.Inverted, Enum.Material.Neon,
			Vector3.new(t * 1.12, t * 0.98, seg.length * 1.01))
		shell.Transparency = 1
		table.insert(shells, { part = shell, seg = seg })
	end
	return {
		parts = (function()
			local list = {}
			for _, s in shells do table.insert(list, s.part) end
			return list
		end)(),
		follow = function(alpha: number)
			-- About 6 flashes a second, each a few frames long.
			local on = (math.floor(os.clock() * 6) % 2) == 0
			for _, s in shells do
				s.part.CFrame = s.seg.model:GetPivot()
				s.part.Transparency = on and (1 - alpha * 0.55) or 1
			end
		end,
	}
end

-- FROZEN: the plates turn to Ice, with shards on the joints, and a shatter burst when it ends.
-- The real arm is holding its pose and ignoring the leader, so a dragon that looks stuck is honest.
function Builders.freeze(self)
	local shells, shards = {}, {}
	for i, seg in self.dragon.segments do
		local t = seg.spec.thickness
		local shell = overlayPart(self.folder, "Ice" .. i, C.Frozen, Enum.Material.Ice,
			Vector3.new(t * 1.16, t * 1.02, seg.length * 1.02))
		shell.Transparency = 0.3
		table.insert(shells, { part = shell, seg = seg })
	end
	for i = 1, #self.dragon.joints do
		for k = 1, 3 do
			local shard = overlayPart(self.folder, "Shard" .. i .. "_" .. k, C.Frozen,
				Enum.Material.Ice, Vector3.new(1.2, 4.5, 1.2))
			shard.Transparency = 0.15
			table.insert(shards, { part = shard, joint = i, k = k })
		end
	end
	return {
		parts = (function()
			local list = {}
			for _, s in shells do table.insert(list, s.part) end
			for _, s in shards do table.insert(list, s.part) end
			return list
		end)(),
		follow = function(alpha: number)
			for _, s in shells do
				s.part.CFrame = s.seg.model:GetPivot()
				s.part.Transparency = 1 - alpha * 0.7
			end
			local pts = self.dragon.points
			for _, s in shards do
				local at = pts[s.joint]
				if at then
					local a = (s.k / 3) * math.pi * 2
					s.part.CFrame = CFrame.new(at + Vector3.new(math.cos(a) * 7, 3, math.sin(a) * 7))
						* CFrame.Angles(math.rad(20), a, 0)
					s.part.Transparency = 1 - alpha * 0.85
				end
			end
		end,
		-- A shatter when it ends: the follower snaps to catch up with the leader after a freeze
		-- (PROTOCOL.md), so the moment is worth marking.
		finish = function()
			local tip = self.dragon:tip()
			if not tip then
				return
			end
			local host = overlayPart(self.folder, "Shatter", C.Frozen, Enum.Material.Neon,
				Vector3.new(1, 1, 1))
			host.Transparency = 1
			host.CFrame = CFrame.new(tip)
			host.Parent = workspace
			local burst = Instance.new("ParticleEmitter")
			burst.Color = ColorSequence.new(C.Frozen)
			burst.Size = NumberSequence.new(2.2, 0.2)
			burst.Lifetime = NumberRange.new(0.5, 1)
			burst.Speed = NumberRange.new(30, 70)
			burst.SpreadAngle = Vector2.new(180, 180)
			burst.LightEmission = 0.9
			burst.Rate = 0
			burst.Parent = host
			burst:Emit(40)
			Debris:AddItem(host, 1.5)
		end,
	}
end

-- LAGGING: thick smoke wraps the head and the eyes dim. The real follower is running up to 800 ms
-- behind the leader, so a half-blind dragon is the right read.
function Builders.fog(self)
	local host = overlayPart(self.folder, "FogHead", C.Lag, Enum.Material.Neon, Vector3.new(1, 1, 1))
	host.Transparency = 1
	local smoke = Instance.new("ParticleEmitter")
	smoke.Color = ColorSequence.new(C.Lag)
	smoke.Size = NumberSequence.new(14, 26)
	smoke.Lifetime = NumberRange.new(1.2, 2.2)
	smoke.Speed = NumberRange.new(2, 7)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Rate = 26
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Parent = host

	local head = self.dragon.segments[5]
	return {
		parts = { host },
		follow = function(alpha: number)
			local cf = self.dragon:headCFrame()
			if cf then
				host.CFrame = cf
			end
			smoke.Rate = 26 * alpha
			if head then
				for _, e in head.eyes do
					-- Dim, not off: off is the dormant look, and a lagging dragon is still alive.
					e.part.Transparency = 0.55 * alpha
				end
			end
		end,
		finish = function()
			if head then
				for _, e in head.eyes do
					e.part.Transparency = 0
				end
			end
		end,
	}
end

-- JAW JAMMED: a lime-glowing boulder stuck in the jaw, so the lower jaw cannot fully close. The
-- real gripper is held at least 18% open, which is also exactly why AttackDetect keeps an absolute
-- floor under fire - this must never read as a roar.
function Builders.butterfingers(self)
	local head = self.dragon.segments[5]
	local t = head and head.spec.thickness or 12
	local rock = overlayPart(self.folder, "JamRock", C.Basalt, Enum.Material.Rock,
		Vector3.new(t * 0.6, t * 0.6, t * 0.6))
	local vein = overlayPart(self.folder, "JamVein", C.Jammed, Enum.Material.Neon,
		Vector3.new(t * 0.64, t * 0.16, t * 0.64))
	vein.Transparency = 0.1
	local light = Instance.new("PointLight")
	light.Color = C.Jammed
	light.Range = 14
	light.Brightness = 2
	light.Parent = vein

	return {
		parts = { rock, vein },
		follow = function(alpha: number)
			local cf = self.dragon:headCFrame()
			if cf then
				local at = cf * CFrame.new(0, -t * 0.25, (head and head.length or 20) * 0.22)
				rock.CFrame = at
				vein.CFrame = at
			end
			rock.Transparency = 1 - alpha
			vein.Transparency = 1 - alpha * 0.9
			light.Brightness = 2 * alpha
		end,
	}
end

-- ---------------------------------------------------------------------------------------------

function DragonEffects.start(self, name: string)
	local builder = Builders[name]
	if not builder then
		return nil      -- an effect nobody has themed yet simply has no overlay, which is correct
	end                 -- and visible in the HUD chips regardless
	local ok, overlay = pcall(builder, self)
	if not ok then
		warn("[DragonEffects] could not build " .. name .. ": " .. tostring(overlay))
		return nil
	end
	return overlay
end

function DragonEffects.stop(self, name: string)
	local overlay = self.active[name]
	if not overlay then
		return
	end
	self.active[name] = nil
	if overlay.finish then
		pcall(overlay.finish)
	end
	for _, p in overlay.parts do
		p:Destroy()
	end
end

-- `effects` is state.effects: a list of { name, intensity, remaining }. Several can stack, and an
-- effect missing from the list this frame has ended - the server is the only thing that decides
-- when, so nothing here runs its own timer.
function DragonEffects.update(self, effects: { any }?)
	local seen = {}
	for _, e in (effects or {}) do
		local name = e.name
		if name then
			seen[name] = true
			if not self.active[name] then
				local overlay = self:start(name)
				if overlay then
					self.active[name] = overlay
				end
			end
			local overlay = self.active[name]
			if overlay and overlay.follow then
				-- Fade over the last half second so the effect visibly runs out rather than
				-- vanishing between frames.
				local remaining = e.remaining or 1
				local alpha = math.clamp(remaining / FADE_S, 0, 1)
				pcall(overlay.follow, alpha)
			end
		end
	end

	-- Collected first, then stopped. `stop` clears the entry it is given, and removing keys from a
	-- table that is mid-generalized-iteration is not something to rely on.
	local ended = {}
	for name in self.active do
		if not seen[name] then
			table.insert(ended, name)
		end
	end
	for _, name in ended do
		self:stop(name)
	end
end

function DragonEffects.clear(self)
	local names = {}
	for name in self.active do
		table.insert(names, name)
	end
	for _, name in names do
		self:stop(name)
	end
end

return DragonEffects
