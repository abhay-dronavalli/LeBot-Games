--!strict
-- One platform per real block, kept in step with the table.
--
-- The gotcha this file exists for: an **anchored** part moved by setting its CFrame does not
-- carry a character standing on it. The player slides off, or is left behind, or gets flung.
-- So a platform that is *moving* is **unanchored** and driven by AlignPosition +
-- AlignOrientation, with the server as network owner, and the physics engine moves the player
-- along with it.
--
-- A platform that is **not** moving is anchored, because a resting block should be exactly
-- where the robot says it is and nothing more. Two stacked cubes left unanchored are two
-- constraint-driven rigid bodies pressing on each other, and the smallest overlap sends the
-- top one tumbling - a stack that was rock solid on the real table fell over here.
--
-- What decides which is which: the block's **cell**. Python no longer tracks a block while
-- the arm carries it - a vision model reads the printed grid a couple of seconds after the
-- gripper opens, so a block simply appears in a new cell between one read and the next, and
-- `held` is always false. This file turns that step into a ride: a block whose cell changed
-- unanchors, gets driven across, and re-anchors when it arrives. A player standing on it goes
-- with it, which is what the crane lift used to do from forward kinematics.
--
-- Speed is capped so a big jump between cells cannot launch the player across the map.
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
local ARRIVED_STUDS = 0.75          -- this close to the goal counts as arrived, and re-anchors
local MOVE_TIMEOUT_S = 6            -- ...and re-anchor regardless after this, so nothing stays
                                    -- unanchored forever if it snags on the way

-- AlignPosition.MaxForce defaults to 10000, which is nowhere near enough to hold a platform
-- up. A platform is a 22-stud cube at density 0.7, so roughly 7500 mass, and at the default
-- gravity of 196.2 that is well over 1e6 of weight to oppose. Under-powered, the constraint
-- cannot hold the part at all: a platform in the middle of a move sags toward the floor
-- instead of crossing to its new cell. The rider speed cap lives in MaxVelocity, not here, so
-- raising these costs nothing in safety.
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
	-- What Python sends for a block it can see is there but cannot name: an overhead camera
	-- cannot read the colour of a cube with another cube sitting on top of it.
	grey = Color3.fromRGB(154, 164, 178),
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

	-- `cell` is what a move is detected against, and `movingUntil` is the deadline that
	-- guarantees the part goes back to being anchored even if it never quite arrives.
	local entry = { part = p, goal = goal, cell = b.cell, movingUntil = 0 }
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
		local p = entry.part

		-- A changed cell means the robot moved this block between two board reads. Hand it to
		-- the constraints for the crossing, so anyone standing on it is carried along, and take
		-- it back as soon as it arrives. The goal is set above either way, so the hand-off in
		-- both directions happens with no jump.
		if b.cell ~= nil and b.cell ~= entry.cell then
			entry.cell = b.cell
			entry.movingUntil = os.clock() + MOVE_TIMEOUT_S
			p.Anchored = false
		end

		if entry.movingUntil > 0 then
			local arrived = (p.Position - target.Position).Magnitude <= ARRIVED_STUDS
			if arrived or os.clock() > entry.movingUntil then
				entry.movingUntil = 0
				p.Anchored = true
				p.CFrame = target        -- land it exactly where Python says, not nearly
			end
		else
			-- Resting. Re-assert the pose every frame: a rider's weight or a neighbouring part
			-- can nudge an anchored block, and the robot's answer is the only correct one.
			p.Anchored = true
			p.CFrame = target
		end

		p.Transparency = b.visible and 0 or LOST_TRANSPARENCY
		p.CanCollide = true
		-- Colour is refreshed every frame, not just at create: a cube that gets buried under
		-- another one reports grey until it is uncovered again, so a part coloured once would
		-- keep whatever colour it had when it first appeared.
		p.Color = COLORS[b.color] or COLORS.grey
	end

	-- A block taken off the table stops being a platform. A block is missing from this list
	-- only because the last board read did not find it, so this is never a dropped camera
	-- frame - but note that a block the arm is holding in the air is not on the board either,
	-- and Python keeps reporting it in the cell it was last read in precisely so that this
	-- does not delete its platform out from under a rider mid-carry.
	for id, entry in self.platforms do
		if not live[id] then
			entry.goal:Destroy()
			entry.part:Destroy()
			self.platforms[id] = nil
		end
	end
end

-- Weld a rider to a platform while it crosses to a new cell, if riding still proves
-- unreliable. Cheaper than fighting the physics: call when the cell changes, release on
-- arrival.
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
