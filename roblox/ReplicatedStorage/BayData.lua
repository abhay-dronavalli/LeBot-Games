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
		color = "orange",
		level = 1,
		solveCells = {{1, 1}},
		note = "Block dropped onto the blade jams it; the block is then a safe step across.",
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
}
