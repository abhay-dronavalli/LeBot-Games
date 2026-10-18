-- BayData -- ONE obstacle per bay. Each 4x3 bay is a single obstacle the operator must clear.
--
-- BLOCKS ARE INTERCHANGEABLE: no obstacle requires a particular colour. The operator places
-- whichever cube is to hand, and any block satisfies any cell. `level` is still enforced,
-- because it is a cube COUNT and not a colour -- level 2 means two cubes stacked in that cell.
--
-- CUBE BUDGET: bays still ask for at most 2 cubes each, which is what the designs were built
-- around back when the limit was two cubes PER COLOUR. The rig owns 14 cubes in total, so that
-- ceiling is now self-imposed rather than physical -- a bay could ask for more, but none has
-- been redesigned to.
--
-- `solveCells` are where blocks must land. They double as the player's footing/route, so every
-- obstacle leaves a walkable way through -- the player is never killed while standing on the
-- thing that solved it.
--
-- col 0-3, row 0-2; row 0 is nearest the bay entrance.
-- `coverRows` limits an area obstacle to certain rows so the bay stays crossable on budget.
return {
	[1] = {
		obstacle = "Saw",
		-- Solved by throwing both levers, not by filling cells: here the crates are a LADDER
		-- to the answer, not the answer. checkSolved skips this bay and the builder owns
		-- state.solved itself. solveCells stays as the advisory "stack here" hint.
		solveMode = "switches",
		banner = "SAW  -  THROW BOTH LEVERS",
		level = 1,
		solveCells = {{0, 1}, {3, 0}},
		-- The two levers cost 1 cube and 2 cubes respectively, plus 1 optional brake crate.
		-- They used to be on different colours because 3 of one colour was over budget; with
		-- colour irrelevant that constraint is gone, but the split stays -- the levers differ
		-- by the HEIGHT you must be standing at, which is the part that was ever load-bearing.
		-- minStand is that crate-top height, and it is what actually enforces the cube cost:
		-- a single crate tops out at 4, a stacked pair at 7. No colour is checked anywhere.
		--
		-- The wall closes from the far end toward the entrance, so row 1 is reached before
		-- row 0. Lever A sits deeper (row 1) and is therefore the timed one; Lever B sits by
		-- the entrance, which the wall reaches last.
		--
		-- A's crate buys a stall when the wall meets it, but only Config.SawWallStallSeconds
		-- and only once, so the whole bay stays a race -- and standing on that crate stops
		-- being safe the moment its stall is spent.
		-- A lever belongs to ONE stand level, and the builder derives everything from it: the
		-- mounting height, the painted level band on the wall, and the gate. `standLevel` is
		-- how many crates you stand on -- 1 for A, 2 for B -- so a lever cannot be reached from
		-- the wrong height in either direction. Standing on the stacked pair does NOT let you
		-- reach down and flip A; each lever costs its own crates, which is the cube budget
		-- argument this whole bay is built on.
		--
		-- Heights are no longer written here because they follow the real cube size
		-- (Mapping.cubeStuds, 6.72 studs) and would only rot if duplicated.
		levers = {
			{id = "A", side = "left",  cell = {0, 1}, level = 1, standLevel = 1},
			{id = "B", side = "right", cell = {3, 0}, level = 2, standLevel = 2},
		},
		note = "Bay seals behind you; a wall of chainsaws closes in from the exit end. Lever A"
			.. " (reachable off one crate) kills the blades and arms Lever B (needs a stacked"
			.. " pair), which halts the wall and sinks it into the floor -- that is the exit."
			.. " Lever heights clear the wall, so it passes under them.",
	},
	[2] = {
		obstacle = "Void",
		level = 1,
		-- Row 2 keeps its floor, so 2 cubes is enough to cross.
		-- The gap this leaves (16 studs) is already nearly twice a running jump (8.67), so the
		-- crates cannot be skipped; widening it to all three rows would only cost the player the
		-- landing, not add difficulty.
		coverRows = {0, 1},
		-- Both in column 1, one per uncovered row: that spaces the crate faces 2 / 4 / 2 studs
		-- apart across the gap, so every hop is comfortably inside a jump even though the gap as
		-- a whole is not. The bay tests the operator's placement, not the player's platforming.
		solveCells = {{1, 0}, {1, 1}},
		note = "No floor over rows 0-1. The blocks ARE the bridge from the catwalk to solid ground."
			.. " Nothing here is lethal but the drop, so the bridge is also the only safe footing.",
	},
	[3] = {
		obstacle = "LaserWalk",
		-- An ACTION bay: there is no fixed set of cells to fill, so checkSolved is skipped and
		-- the obstacle owns state.solved. It resolves when the player stands on the last cell
		-- of the route, not when the crate merely arrives there.
		solveMode = "action",
		banner = "LASER WALK  -  FOLLOW THE CRATE",
		level = 1,
		-- Deliberately NO solveCells: the route is generated per run (Config.LaserRoute*), so
		-- the answer does not exist until the bay arms. One cube is the whole cost -- it is the
		-- same crate the whole way across, walked ahead of the player one cell at a time.
		note = "Every cell of the grid is lethal. The one crate switches off whatever cell"
			.. " it sits in, and only the next cell of the route will accept it, so the operator"
			.. " walks you across. The cell the crate just left stays safe for a few seconds"
			.. " after the crate lands -- that gap is your window to follow it.",
	},
	[4] = {
		obstacle = "Lava",
		level = 1,
		coverRows = {0, 1},   -- row 2 stays dry, so 2 stepping stones is enough
		solveCells = {{1, 0}, {1, 1}},
		note = "Lava rises on a timer. Blocks stand proud of the max level as dry stepping stones.",
	},
	[5] = {
		obstacle = "CrusherRoof",
		level = 2,
		solveCells = {{1, 1}},
		note = "Ceiling descends; a stacked pair props it and the roof halts on the stack.",
	},
	[6] = {
		obstacle = "Mobs",
		level = 1,
		solveCells = {{0, 1}, {3, 1}},
		note = "Blocks seal the two wall spawners so the mobs stop coming; the lane stays open.",
	},
	[7] = {
		obstacle = "ArrowTurrets",
		level = 1,
		solveCells = {{1, 1}, {2, 1}},
		note = "Wall dispensers fire volleys across the bay. The blocks are hard cover -- arrows die"
			.. " against them -- and placing both shuts the turrets down.",
	},
	[8] = {
		obstacle = "DarkZone",
		level = 1,
		solveCells = {{1, 1}, {2, 1}},
		-- NEEDS A DESIGN PASS: this bay was "teal blocks GLOW", which was the one obstacle solved
		-- by what the block emits rather than what it blocks -- and it was the only bay whose
		-- mechanic was tied to a specific colour. With any block accepted, either every crate
		-- lights the dark or the bay needs a different idea.
		note = "Lights out, with pits you cannot see. The blocks light the way.",
	},
	[9] = {
		obstacle = "Ice",
		level = 1,
		solveCells = {{0, 1}, {3, 1}},
		finale = true,
		note = "Finale: frictionless ice. You slide through a pinch point with lethal drops either"
			.. " side; the blocks are guard rails that cover them.",
	},
}
