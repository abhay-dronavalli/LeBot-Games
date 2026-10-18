--!strict
-- One platform per real block, kept in step with the table.
--
-- The gotcha this file exists for: an **anchored** part moved by setting its CFrame does not
-- carry a character standing on it. The player slides off, or is left behind, or gets flung.
-- Since the crane lift (a player riding a platform the real arm carries) is the demo's money
-- shot, platforms are **unanchored** and driven by AlignPosition + AlignOrientation, with the
-- server as network owner. The physics engine then moves the player with the platform.
--
-- Speed is capped so a jumpy camera frame cannot launch the player across the map.
--
--   local BlockSync = require(script.Parent.BlockSync)
--   local sync = BlockSync.new(workspace)
--   Bridge.onHello(function(h) sync:setCube(h.space.cube_mm) end)
--   Bridge.onState(function(s) sync:update(s.blocks) end)

local Mapping = require(script.Parent.Mapping)

local BlockSync = {}
BlockSync.__index = BlockSync

local MAX_SPEED = 60                -- studs/s; above this a rider gets flung
local RESPONSIVENESS = 40           -- AlignPosition stiffness

-- AlignPosition.MaxForce defaults to 10000, which is nowhere near enough to hold a platform
-- up. A platform is about 22 x 6.5 x 22 studs at density 0.7, so roughly 2200 mass, and at the
-- default gravity of 196.2 that is about 4.3e5 of weight to oppose - 43x the default limit.
-- Under-powered, the constraint cannot lift the part: platforms sag toward the floor, and a
-- *held* block (CanCollide = false, so nothing catches it) sinks straight through the world
-- until the engine destroys it at FallenPartsDestroyHeight. The rider speed cap lives in
-- MaxVelocity, not here, so raising these costs nothing in safety.
local MAX_FORCE = 1e8
local MAX_TORQUE = 1e8
local LOST_TRANSPARENCY = 0.6       -- a block the camera cannot see right now

local COLORS: { [string]: Color3 } = {
	red = Color3.fromRGB(229, 72, 77),
	orange = Color3.fromRGB(247, 107, 21),
	yellow = Color3.fromRGB(255, 230, 41),
	green = Color3.fromRGB(70, 167, 88),
	teal = Color3.fromRGB(18, 165, 148),
	["light blue"] = Color3.fromRGB(94, 176, 239),
	blue = Color3.fromRGB(62, 99, 221),
	purple = Color3.fromRGB(142, 78, 198),
	pink = Color3.fromRGB(233, 61, 130),
	grey = Color3.fromRGB(154, 164, 178),   -- what Python sends for a held block
}

function BlockSync.new(parent: Instance)
	local self = setmetatable({}, BlockSync)
	self.folder = Instance.new("Folder")
	self.folder.Name = "Blocks"
	self.folder.Parent = parent
	self.platforms = {} :: { [number]: any }
	self.cubeMm = 48
	return self
end

function BlockSync.setCube(self, cubeMm: number?)
	self.cubeMm = cubeMm or 48
end

function BlockSync.create(self, b: any)
	local size = Mapping.blockSize(self.cubeMm)

	local p = Instance.new("Part")
	p.Name = ("Block_%d_%s"):format(b.id, tostring(b.color))
	p.Size = size
	p.Color = COLORS[b.color] or Color3.fromRGB(154, 164, 178)
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true               -- resting; update() unanchors it when the arm takes it
	p.CanCollide = true
	p.Massless = false
	p.CustomPhysicalProperties = PhysicalProperties.new(0.7, 1.0, 0, 100, 100) -- grippy underfoot
	p.CFrame = CFrame.new(Mapping.blockPosition(b, self.cubeMm)) * Mapping.blockOrientation(b)
	p.Parent = self.folder

	local att = Instance.new("Attachment")
	att.Name = "Drive"
	att.Parent = p

	local goal = Instance.new("Attachment")
	goal.Name = ("Goal_%d"):format(b.id)
	goal.CFrame = p.CFrame
	goal.Parent = workspace.Terrain  -- a world-anchored attachment to drive toward

	local pos = Instance.new("AlignPosition")
	pos.Attachment0 = att
	pos.Attachment1 = goal
	pos.MaxVelocity = MAX_SPEED
	pos.MaxForce = MAX_FORCE
	pos.Responsiveness = RESPONSIVENESS
	pos.ApplyAtCenterOfMass = true
	pos.Parent = p

	local rot = Instance.new("AlignOrientation")
	rot.Attachment0 = att
	rot.Attachment1 = goal
	rot.MaxTorque = MAX_TORQUE
	rot.Responsiveness = RESPONSIVENESS
	rot.Parent = p

	-- The server must own these parts or a rider's client fights the server over position.
	pcall(function()
		p:SetNetworkOwner(nil)
	end)

	local entry = { part = p, goal = goal }
	self.platforms[b.id] = entry
	return entry
end

function BlockSync.update(self, blocks: { any }?)
	if blocks == nil then
		return
	end

	local live = {}
	for _, b in blocks do
		live[b.id] = true
		-- Rebuild if the part has left the tree. Without this, one lost part is permanent:
		-- the entry keeps `live[b.id]` set so the cleanup below never clears it, and `or
		-- self:create(b)` never fires again, so the block silently stops existing for the
		-- rest of the session.
		local entry = self.platforms[b.id]
		if entry == nil or entry.part.Parent == nil then
			if entry ~= nil then
				entry.goal:Destroy()
				entry.part:Destroy()
				self.platforms[b.id] = nil
			end
			entry = self:create(b)
		end
		local target = CFrame.new(Mapping.blockPosition(b, self.cubeMm)) * Mapping.blockOrientation(b)
		entry.goal.CFrame = target

		-- Anchored while resting, unanchored while carried.
		--
		-- A resting block has no reason to be simulated: it should be exactly where the robot
		-- says it is, full stop. Leaving it unanchored meant two stacked cubes were two
		-- constraint-driven rigid bodies pressing on each other, and the smallest overlap sent
		-- the top one tumbling - a stack that was perfectly stable on the real table fell over
		-- here. Anchoring makes a stack exact and immovable.
		--
		-- A carried block is the opposite case, and the reason the part is unanchored at all:
		-- an anchored part moved by CFrame does not carry a player standing on it, and being
		-- carried is the whole point of the lift. So it unanchors for the duration and
		-- AlignPosition takes over. The goal is kept in sync either way, so the hand-off in
		-- both directions happens with no jump.

		local p = entry.part
		if b.held then
			p.Anchored = false
		else
			p.Anchored = true
			p.CFrame = target
		end
		p.Transparency = (b.visible or b.held) and 0 or LOST_TRANSPARENCY
		-- A held block stays solid. Riding a carried block IS the crane lift - the player jumps
		-- on while it rests on the table and gets carried across the map - so turning collision
		-- off while held, as this used to, removed the one thing the feature exists for. The
		-- speed cap in MaxVelocity is what keeps the rider safe, not loss of collision.
		p.CanCollide = true
		-- Colour has to be refreshed every frame, not just at create: a block reports grey
		-- while it is in the jaw and its own colour again once it is put down, so a part
		-- coloured only once would stay whatever it was when it first appeared.
		p.Color = COLORS[b.color] or COLORS.grey
	end

	-- A block taken off the table stops being a platform. Python only drops a track after it
	-- has been gone for seconds, so this is not a dropped camera frame.
	for id, entry in self.platforms do
		if not live[id] then
			entry.goal:Destroy()
			entry.part:Destroy()
			self.platforms[id] = nil
		end
	end
end

-- Weld a rider to a platform while it is being carried, if riding still proves unreliable.
-- Cheaper than fighting the physics: call on held, release on landing.
function BlockSync.attachRider(self, id: number, character: Model): Instance?
	local entry = self.platforms[id]
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not entry or not root then
		return nil
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = entry.part
	weld.Parent = entry.part
	return weld
end

return BlockSync
