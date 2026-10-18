--!strict
-- Sheet millimetres -> Roblox studs. The only place the scale is defined.
--
-- Python sends everything in the sheet frame: origin at the printed sheet's top-left corner,
-- +x right, +y down the page (away from the arm), +z up off the paper. Roblox is Y-up, so
-- sheet y becomes Roblox Z and sheet z becomes Roblox Y.
--
-- One scale applies to all three axes, so a 48 mm block is a true 22-stud cube. That is far
-- above the ~7 studs a default character clears, so Main raises the player's JumpHeight to
-- match instead of squashing the block (see Mapping.jumpHeight). An earlier version scaled
-- height separately via a LEVEL_STUDS constant to keep one block equal to one jumpable step,
-- but a carried block then read as a slab - and the carried block is the one the player rides.
--
-- Retune these live: nothing on the Python side depends on them.

local Mapping = {}

Mapping.STUDS_PER_MM = 0.46      -- the sheet becomes about 129 x 99 studs
Mapping.ORIGIN = Vector3.new(0, 0, 0)   -- where the sheet's top-left corner sits in the world

-- A real cube renders as a real cube: the same scale on all three axes, so a 48 mm block is
-- 22 studs on a side. An earlier version squashed height to a flat 6.5 studs so that one block
-- was exactly one jumpable step, but a carried block then read as a slab instead of the cube it
-- actually is - and the carried block is the thing the player rides, so it is the one that has
-- to look right. Keeping it cubic costs the free step: 22 studs is far above the ~7 stud default
-- jump, so Main raises the player's JumpHeight to match (see Mapping.jumpHeight).
function Mapping.cubeStuds(cubeMm: number): number
	return cubeMm * Mapping.STUDS_PER_MM
end

-- How high a player has to jump to climb onto a block resting on the table, plus margin for
-- hip height and a sloppy approach.
function Mapping.jumpHeight(cubeMm: number): number
	return Mapping.cubeStuds(cubeMm) + 5
end

-- A point as Python sends it ({x, y, z} in mm) -> a world position.
function Mapping.point(p: { x: number, y: number, z: number }): Vector3
	local s = Mapping.STUDS_PER_MM
	return Mapping.ORIGIN + Vector3.new(p.x * s, p.z * s, p.y * s)
end

-- A block's platform centre. Height comes from its stack level, not its scaled mm, except
-- while it is held: then the real carry height is the whole point, so use z directly.
function Mapping.blockPosition(b, cubeMm: number): Vector3
	local s = Mapping.STUDS_PER_MM
	local w = Mapping.cubeStuds(cubeMm)
	local y
	if b.held then
		y = b.z * s + w / 2
	else
		y = b.level * w + w / 2     -- cubes stack on each other, so one level is one cube tall
	end
	return Mapping.ORIGIN + Vector3.new(b.x * s, y, b.y * s)
end

function Mapping.blockSize(cubeMm: number): Vector3
	local w = Mapping.cubeStuds(cubeMm)
	return Vector3.new(w, w, w)
end

-- Sheet yaw is degrees counterclockwise seen from above, wrapping every 90 degrees.
function Mapping.blockOrientation(b): CFrame
	return CFrame.Angles(0, math.rad(-b.yaw), 0)
end

return Mapping
