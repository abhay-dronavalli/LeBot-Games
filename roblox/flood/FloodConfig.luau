-- Studio location: ReplicatedStorage.Flood.FloodConfig (ModuleScript)
-- Rising Flood tuning. Heights are in studs relative to the arena floor top.
local Config = {
	ROUND_TIME = 180, -- fallback; each difficulty sets its own round time below
	GRACE_TIME = 5, -- seconds before the water starts rising
	COUNTDOWN = 3,
	RESULT_TIME = 4, -- seconds the win/lose banner shows before everyone returns to the arcade

	-- One real block = one giant cube + ledge. Keep STEP_HEIGHT under the
	-- character jump height (7.2) so each new ledge is a jumpable step.
	STEP_HEIGHT = 5,
	BLOCK_WIDTH = 6,
	LEDGE_LENGTH = 7,
	LEDGE_THICKNESS = 1.2,
	MAX_STEPS = 12,
	-- tallest the tower may get, so a player on the top ledge still fits under the ceiling;
	-- long paths use shorter steps (12 squares -> 4-stud steps)
	MAX_TOWER_HEIGHT = 48,

	-- The tower is built by moving ONE real block along a path on the 3x4 grid sheet: every time
	-- the block reaches the next square of the path, the tower grows by one. Difficulty picks the
	-- path length and round time (Difficulty attribute on ServerStorage.Modes.Flood: Easy, Medium,
	-- Hard, or Random = rolled for the NEXT round while players are still in the lobby).
	-- Round times are paced for the vision board, not for a human with a mouse. One square costs
	-- a release plus a model read (~2 s trigger delay + ~3.5 s for the call, see bridge/board.py)
	-- on top of the time it takes to actually pick the cube up and set it down, so budget roughly
	-- 20 s per square and leave room to fumble one. Shorten these and the tower cannot be finished
	-- however well the pair plays. Mode.MaxDuration in modes/Flood/Module.luau must stay above the
	-- longest of them, or the arcade times the round out from underneath it.
	DIFFICULTY = {
		Easy = { cells = 6, time = 180 },
		Medium = { cells = 9, time = 240 },
		Hard = { cells = 12, time = 300 },
	},
	DEFAULT_DIFFICULTY = "Easy",
	TARGET_STEPS = 5, -- only used if the path can't be built
	WATER_START = 0.3, -- a shallow puddle is visible as soon as the round starts
	-- 1 = the liquid reaches its top level exactly at 0:00; lower = slower (0.8 -> 80% of the way)
	RISE_SPEED = 0.8,

	-- Players are flooded when the water reaches their waist (HumanoidRootPart). Characters are
	-- scaled 1.5x (ServerScriptService.CharacterScale), so the waist sits ~4.8 above the feet.
	WAIST_HEIGHT = 4.8,

	-- The printed grid sheet (assets/markers/grid_sheet_3x4.print.html), in mm, measured from the
	-- sheet's top-left corner = the inner corner of ArUco tag 0. Rows A-C go down the sheet (row A
	-- is on the arm's side), columns 1-4 go across.
	GRID = { originX = 25.4, originY = 22.225, cell = 57.15, rows = { "A", "B", "C" }, cols = 4 },

	-- Tower collapse (block count drops mid-round) speeds the water up.
	SURGE_MULTIPLIER = 3,
	SURGE_DURATION = 4,

	-- Vision can briefly lose a marker; a lower count from the bridge must hold
	-- this long before the tower collapses.
	DECREASE_CONFIRM = 0.6,

	BLOCK_COLORS = {
		Color3.fromRGB(230, 70, 70), -- red
		Color3.fromRGB(70, 130, 235), -- blue
		Color3.fromRGB(80, 200, 100), -- green
		Color3.fromRGB(245, 205, 60), -- yellow
		Color3.fromRGB(245, 140, 50), -- orange
		Color3.fromRGB(165, 95, 220), -- purple
	},
}

-- Step height for a tower of `target` blocks.
function Config.stepFor(target)
	return math.min(Config.STEP_HEIGHT, Config.MAX_TOWER_HEIGHT / math.max(target, 1))
end

-- Where the water stops: high enough to flood anyone on the second-to-last ledge (their waist is
-- under it), low enough that the top ledge is safe.
function Config.waterEndFor(target, step)
	return (target - 1) * step + Config.WAIST_HEIGHT + 0.3
end

-- kept for anything that still reads the old constant
Config.WATER_END = Config.waterEndFor(Config.TARGET_STEPS, Config.STEP_HEIGHT)

return Config
