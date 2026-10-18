-- Mapping -- sheet millimetres -> obby studs. The only place the mat-to-bay scale lives.
--
-- Python sends everything in the sheet frame (PROTOCOL.md): origin at the printed sheet's
-- top-left corner, +x right, +y down the page (away from the arm), +z up off the paper.
-- Roblox is Y-up, so sheet y becomes world Z and sheet z becomes world Y. Both grids run the
-- same direction -- mat row A is nearest the arm, bay row 0 is nearest the entrance, and the
-- arm sits at the entrance end -- so there is no axis flip anywhere in here.
--
-- The scale is NOT a free parameter, unlike the bridge branch's 0.46 studs/mm. The mat's 4x3
-- grid has to land on the active bay's 4x3 grid of Config.CellSize cells, which pins it:
--
--     studs per mm = Config.CellSize / hello.space.grid.cell_mm = 8 / 57.15 = 0.1399825
--
-- Verified against the baked Cell_c_r anchors: all 12 mat cell centres land on their anchor to
-- within 2e-15 studs. Two things fall out of that number, both lucky:
--
--   * a 48 mm cube becomes 6.72 studs, so ONE cube is climbable against the ~12.8 studs a
--     default jump clears and a stacked PAIR (13.44) is not. That is exactly the gate Bay 1's
--     two levers rely on, arriving as a consequence of the real scale rather than a tuned
--     constant.
--   * the arm base lands at X = 16.00, the exact centre of the bay's 32 stud width.
--
-- What does NOT fall out nicely: the real arm's pan axis is 69 mm off the paper (9.66 studs)
-- while its wrist reaches 306 mm (42.9 studs). The SO-101 is a table arm that reaches up and
-- over, so a faithful mirror stands at the bay entrance and towers over it -- it is not the
-- ceiling-gantry arm Config.GantryHeight was sized for. See Config.GantryHeight.
--
-- ORIGIN is derived from the active bay's Cell_0_0 anchor rather than hardcoded, so following
-- the player from bay to bay is one setActiveBay call and the baked geometry stays the single
-- source of truth for where a cell actually is.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local Mapping = {}

-- Defaults from robot/assets/workspace_sheet.json, so this module is usable before the hello
-- frame lands. setSpace replaces them with whatever the server actually measured.
Mapping.CellMm = 57.15
Mapping.GridOriginMm = {25.4, 22.225}
Mapping.GridRows = 3
Mapping.GridCols = 4
Mapping.CubeMm = 48
Mapping.SheetMm = {279.4, 215.9}
Mapping.ArmBaseMm = {139.7, -44.5}

Mapping.STUDS_PER_MM = Config.CellSize / Mapping.CellMm

-- HEIGHT is scaled separately from the floor plan, and only height.
--
-- The horizontal scale is pinned by the cell grid and must not move. Vertical is not pinned by
-- anything, and at the same 0.14 the real arm's 306 mm of reach becomes 43 studs -- which is
-- taller than the warehouse and turns the Sky Arm into a tower standing at the door rather than
-- the gantry crane sliding along the roof. Compressing height keeps the arm under its own rails
-- and a carried cube under the ceiling.
--
-- This does NOT touch a resting cube: its height comes from its stack level (level * cubeStuds),
-- so 6.72 and 13.44 studs are untouched and Bay 1's lever gate is unaffected. Only a HELD cube
-- and the arm's own points use it, and both need to agree or the jaw and the cube it is carrying
-- drift apart.
--
-- Derived, not picked: the arm's usable span in-world is floor to shoulder, about
-- GantryHeight - SHOULDER_OFFSET, against roughly 250 mm of real lift.
Mapping.HEIGHT_PER_MM = (Config.GantryHeight - 4) / 250

Mapping.ORIGIN = Vector3.new(0, 0, 0)
Mapping.activeBay = nil

local function recompute()
	Mapping.STUDS_PER_MM = Config.CellSize / Mapping.CellMm
	if Mapping.activeBay then
		Mapping.setActiveBay(Mapping.activeBay)
	end
end

-- Static geometry from the hello frame. Everything here is measured on the robot side (the
-- sheet size comes from the tag fit, the grid from workspace_sheet.json), so ask rather than
-- assume: an earlier bridge-branch bug hardcoded the sheet portrait when it is landscape and
-- built a floor pad that stopped 29 studs short of where real blocks mapped to.
function Mapping.setSpace(space)
	if type(space) ~= "table" then
		return
	end
	local g = space.grid
	if type(g) == "table" then
		Mapping.CellMm = tonumber(g.cell_mm) or Mapping.CellMm
		if type(g.origin_mm) == "table" and #g.origin_mm >= 2 then
			Mapping.GridOriginMm = {tonumber(g.origin_mm[1]), tonumber(g.origin_mm[2])}
		end
		if type(g.rows) == "table" then Mapping.GridRows = #g.rows end
		if type(g.cols) == "table" then Mapping.GridCols = #g.cols end
	end
	Mapping.CubeMm = tonumber(space.cube_mm) or Mapping.CubeMm
	if type(space.sheet) == "table" then
		Mapping.SheetMm = {tonumber(space.sheet.w_mm), tonumber(space.sheet.h_mm)}
	end
	if type(space.arm_base_mm) == "table" and #space.arm_base_mm >= 2 then
		Mapping.ArmBaseMm = {tonumber(space.arm_base_mm[1]), tonumber(space.arm_base_mm[2])}
	end

	-- The mat is 4 cols x 3 rows and so is a bay. If that ever stops being true the scale
	-- below is meaningless rather than merely wrong, so say so loudly instead of drifting.
	if Mapping.GridCols ~= Config.BayCols or Mapping.GridRows ~= Config.BayRows then
		warn(("[Mapping] grid is %dx%d but a bay is %dx%d -- the mat no longer maps onto a bay")
			:format(Mapping.GridCols, Mapping.GridRows, Config.BayCols, Config.BayRows))
	end
	recompute()
end

-- Point ORIGIN so that mat cell (0,0)'s centre lands exactly on this bay's Cell_0_0 anchor,
-- and sheet z = 0 (the paper) sits on the bay floor.
function Mapping.setActiveBay(bayModel)
	Mapping.activeBay = bayModel
	local anchors = bayModel and bayModel:FindFirstChild("CrateAnchors")
	local first = anchors and anchors:FindFirstChild("Cell_0_0")
	if not first then
		warn("[Mapping] no Cell_0_0 anchor under " .. tostring(bayModel and bayModel:GetFullName()))
		return
	end
	local s = Mapping.STUDS_PER_MM
	local cx = (Mapping.GridOriginMm[1] + 0.5 * Mapping.CellMm) * s
	local cz = (Mapping.GridOriginMm[2] + 0.5 * Mapping.CellMm) * s
	Mapping.ORIGIN = Vector3.new(first.Position.X - cx, first.Position.Y, first.Position.Z - cz)
end

-- A point as Python sends it ({x, y, z} in mm) -> a world position.
function Mapping.point(p)
	local s = Mapping.STUDS_PER_MM
	return Mapping.ORIGIN + Vector3.new(p.x * s, p.z * Mapping.HEIGHT_PER_MM, p.y * s)
end

function Mapping.cubeStuds()
	return Mapping.CubeMm * Mapping.STUDS_PER_MM
end

-- Which cell a sheet-frame point is in, or nil when it is off the grid (the inventory tray,
-- or the bare mat). Deliberately the same floor arithmetic as world.py's _cell_of, so the two
-- sides agree on the boundary case rather than each rounding its own way. The returned col and
-- row are already obby indices -- the mat's printed labels are 1-based columns and lettered
-- rows, but the wire carries millimetres and the arrays are 0-indexed either side.
function Mapping.cellOf(xMm, yMm)
	local col = math.floor((xMm - Mapping.GridOriginMm[1]) / Mapping.CellMm)
	local row = math.floor((yMm - Mapping.GridOriginMm[2]) / Mapping.CellMm)
	if col < 0 or col >= Mapping.GridCols or row < 0 or row >= Mapping.GridRows then
		return nil
	end
	return col, row
end

function Mapping.cellCentreMm(col, row)
	return Mapping.GridOriginMm[1] + (col + 0.5) * Mapping.CellMm,
		Mapping.GridOriginMm[2] + (row + 0.5) * Mapping.CellMm
end

-- Where a block's centre sits. A resting block's height comes from its stack level, not its
-- measured z: the robot snaps a resting cube to its cell and the game should be exactly where
-- it says. A held block is the opposite case -- the real carry height is the whole point, and
-- the player may be standing on it -- so its z is used directly.
function Mapping.blockPosition(b)
	local s = Mapping.STUDS_PER_MM
	local w = Mapping.cubeStuds()
	local y
	if b.held then
		-- Compressed height, matching Mapping.point, so the cube stays in the jaw carrying it.
		y = b.z * Mapping.HEIGHT_PER_MM + w / 2
	else
		-- Stack level, NOT measured millimetres: a resting cube should be exactly where the
		-- robot says, and these are the heights Bay 1's lever gate is tuned against.
		y = (b.level or 0) * w + w / 2
	end
	return Mapping.ORIGIN + Vector3.new(b.x * s, y, b.y * s)
end

function Mapping.blockSize()
	local w = Mapping.cubeStuds()
	return Vector3.new(w, w, w)
end

-- Sheet yaw is degrees counterclockwise seen from above, wrapping every 90 degrees.
function Mapping.blockOrientation(b)
	return CFrame.Angles(0, math.rad(-(b.yaw or 0)), 0)
end

return Mapping
