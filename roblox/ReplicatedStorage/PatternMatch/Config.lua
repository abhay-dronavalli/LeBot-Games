-- ReplicatedStorage.PatternMatch.Config
-- Tunables for Pattern Match. See docs/pattern-match-v1.md section 8.

return {
	useFakeState = true,                 -- Core.StateStore stand-in (fake arm, Debug hook, debugAutoSolve); set false once the real core is in
	gridCols = 4, gridRows = 3,          -- printed sheet: columns 1-4 (tag 0 -> tag 1), rows A-C (arm -> tripod)
	gridOriginCm = Vector2.new(2.540, 2.223), -- table cm of cell A1's outer corner (the corner nearest tag 0)
	cellSizeCm = 5.715,                  -- measured on the printed sheet
	flipX = false,                       -- true mirrors columns (1 <-> 4) if the sheet or tags turn out reversed
	flipY = false,                       -- true mirrors rows (A <-> C)
	cellTolerance = 0.7,
	maxStackGlobal = 2,                  -- hard cap on tower height; a block at level >= this always counts as extra
	ignoreZones = { tray = true },       -- block zones that never count (plan.md: the inventory tray maps to nothing)
	boardCellStuds = 4,                  -- studs per grid cell on the boards; with cellSizeCm this is the cm -> stud scale
	twinBaseOffsetCm = 9,                -- arm twin base center, measured from the grid's row A edge toward the operator
	-- SO-101 link lengths in cm: joint-to-joint distances from TheRobotStudio's so101_new_calib.urdf
	twinLinksCm = { baseHeight = 6.2, shoulderHeight = 5.4, upperArm = 11.6, forearm = 13.5, wrist = 6.4,
	                jawHinge = 3.6, gripper = 9.8 },
	-- Target generation only uses colors listed here. Remove an entry if vision can't separate it.
	-- Values are the Apprentice 3D view's block palette.
	colors = { red = Color3.fromHex("e2383f"), orange = Color3.fromHex("f5862a"), yellow = Color3.fromHex("f6c933"),
	           teal = Color3.fromHex("16a59b"), skyblue = Color3.fromHex("62bdea"), purple = Color3.fromHex("8a5cc7") },
	-- The shift: one countdown; tickets (target patterns) arrive on a rail and are made one at a time.
	shiftSeconds = 180,
	ticketIntervalMin = 12, ticketIntervalMax = 20, -- seconds between ticket arrivals (random in this range)
	ticketRailMax = 4,                   -- tickets the rail holds; the arrival timer pauses while it is full
	ticketBlocksMin = 2, ticketBlocksMax = 4, -- blocks per ticket, towers included (towers up to maxStackGlobal)
	stackChanceStart = 0.2,              -- chance a ticket block goes on top of another, ramping linearly over
	stackChanceEnd = 0.6,                --   the shift from start to end
	ticketTimeBonus = 3,                 -- seconds added to the shift timer per completed ticket
	ticketPoints = { ticket = 1, flat = 1, stacked = 3 }, -- per ticket, per level 0 block, per level 1 block
	holdToClear = 1,
	attractEnabled = true,               -- Idle: demo loop on the boards (PatternMatch.Attract)
	attractPlaceInterval = 0.7,          -- seconds between the demo's block placements
	attractPatterns = 5,                 -- demo patterns per set before a fresh set is generated
	modeSelectSeconds = 15,
	modeConfirmSeconds = 1.5,            -- "HARD MODE" confirmation before the shift
	resultsSeconds = 10,
	debugAutoSolve = false,              -- testing: fake StateStore rebuilds the board for the active ticket 3 s after it becomes active
	debugFastTimers = false,             -- testing: every game timer (shift, ticket arrivals, events, reveal) runs 4x faster
	debugForceMode = nil,                -- testing: "easy" or "hard" makes ModeSelect pick that mode; nil picks Easy
	debugEventEvery = nil,               -- testing: seconds between events in both modes, instead of easy/hard.eventEvery
	hard = { showSeconds = 5, hideSeconds = 5, eventEvery = 30 },
	easy = { eventEvery = 45 },
	vanishSeconds = 6, vanishCount = { 1, 2 },
	events = { "vanish", "tremor", "inverted" },
	twinJoints = { shoulder_pan = {sign=1, offset=0}, shoulder_lift = {sign=1, offset=0}, elbow_flex = {sign=1, offset=0},
	               wrist_flex = {sign=1, offset=0}, wrist_roll = {sign=1, offset=0}, gripper = {sign=1, offset=0} },
	-- Arm twin's folded rest pose, shown while there is no arm data (no sample yet, an empty one, or none
	-- for ArmTwin.Driver's stale timeout) and used for any joint a sample leaves out. Same units as
	-- StateStore.arm (degrees, gripper 0..100) and run through twinJoints like a sample, so after tuning set
	-- it to what the real arm reports at rest. Upper arm up and leaning back, forearm folded forward, hand
	-- hanging just in front of the base: highest point ~16.2 studs above the base (elbow hub).
	twinRestPose = { shoulder_pan = 0, shoulder_lift = 125, elbow_flex = -128, wrist_flex = -76, wrist_roll = 0, gripper = 0 },
}
