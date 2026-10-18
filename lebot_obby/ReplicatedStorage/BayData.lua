-- BayData -- ONE obstacle per bay. Each 4x3 bay is a single obstacle the operator must clear.
--
-- CUBE BUDGET: the physical rig has only TWO cubes of each colour, so a bay may never ask for
-- more than 2 of one colour. That means: one cell at level 2 (2 cubes), OR two cells at level 1
-- (2 cubes), OR one cell at level 1. Anything more is unsolvable on the real table.
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
		color = "orange",
		level = 1,
		solveCells = {{0, 1}, {3, 0}},
		-- Cube budget (2 per colour) is spent exactly: 1 orange for the Lever A step, 1 spare
		-- orange for the optional brake crate, 2 red for the Lever B stack. Lever A needs 1
		-- cube and B needs 2, so a single colour would need 3 -- over budget. That is what
		-- forces the two levers onto different colours.
		-- minStand is the crate-top height the player must be standing on, which is what
		-- actually enforces the cube cost: a single crate tops out at 4, a stacked pair at 7.
		--
		-- The wall closes from the far end toward the entrance, so row 1 is reached before
		-- row 0. Lever A sits deeper (row 1) and is therefore the timed one; Lever B sits by
		-- the entrance, which the wall reaches last.
		--
		-- A's crate buys a stall when the wall meets it, but only Config.SawWallStallSeconds
		-- and only once, so the whole bay stays a race -- and standing on that crate stops
		-- being safe the moment its stall is spent.
		levers = {
			{id = "A", side = "left",  cell = {0, 1}, color = "orange", level = 1,
				height = 8.6,  minStand = 3},
			{id = "B", side = "right", cell = {3, 0}, color = "red",    level = 2,
				height = 11.8, minStand = 6},
		},
		brakeColor = "orange",
		note = "Bay seals behind you; a wall of chainsaws closes in from the exit end. Lever A"
			.. " (reachable off one crate) kills the blades and arms Lever B (needs a stacked"
			.. " pair), which halts the wall and sinks it into the floor -- that is the exit."
			.. " Lever heights clear the wall, so it passes under them.",
	},
	[2] = {
		obstacle = "Void",
		color = "red",
		level = 1,
		coverRows = {0, 1},   -- row 2 keeps its floor, so 2 cubes is enough to cross
		solveCells = {{1, 0}, {1, 1}},
		note = "No floor over rows 0-1. The blocks ARE the bridge from the catwalk to solid ground.",
	},
	[3] = {
		obstacle = "Laser",
		color = "yellow",
		level = 1,
		solveCells = {{1, 1}},
		note = "Heist-grid of red beams. The mirror crate cuts power to the whole lattice.",
	},
	[4] = {
		obstacle = "Lava",
		color = "blue",
		level = 1,
		coverRows = {0, 1},   -- row 2 stays dry, so 2 stepping stones is enough
		solveCells = {{1, 0}, {1, 1}},
		note = "Lava rises on a timer. Blocks stand proud of the max level as dry stepping stones.",
	},
	[5] = {
		obstacle = "CrusherRoof",
		color = "green",
		level = 2,
		solveCells = {{1, 1}},
		note = "Ceiling descends; a stacked pair props it and the roof halts on the stack.",
	},
	[6] = {
		obstacle = "Mobs",
		color = "purple",
		level = 1,
		solveCells = {{0, 1}, {3, 1}},
		note = "Blocks seal the two wall spawners so the mobs stop coming; the lane stays open.",
	},
	[7] = {
		obstacle = "ArrowTurrets",
		color = "yellow",
		level = 1,
		solveCells = {{1, 1}, {2, 1}},
		note = "Wall dispensers fire volleys across the bay. The blocks are hard cover -- arrows die"
			.. " against them -- and placing both shuts the turrets down.",
	},
	[8] = {
		obstacle = "DarkZone",
		color = "teal",
		level = 1,
		solveCells = {{1, 1}, {2, 1}},
		note = "Lights out, with pits you cannot see. Teal blocks GLOW -- the only obstacle solved by"
			.. " what the block emits rather than what it blocks.",
	},
	[9] = {
		obstacle = "Ice",
		color = "red",
		level = 1,
		solveCells = {{0, 1}, {3, 1}},
		finale = true,
		note = "Finale: frictionless ice. You slide through a pinch point with lethal drops either"
			.. " side; the blocks are guard rails that cover them.",
	},
}
