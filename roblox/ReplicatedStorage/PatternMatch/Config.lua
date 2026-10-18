-- ReplicatedStorage.PatternMatch.Config
-- Tunables for Pattern Match. See docs/pattern-match-v1.md section 8.

return {
	-- The robot link (core's ServerScriptService.Bridge, PROTOCOL.md). Core.StateStore connects once and
	-- reads every state frame from it; with useBridge = false, or no hello within bridgeHelloSeconds, it
	-- runs the fake generator instead (fake arm, Debug hook, debugAutoSolve) so the game runs with no robot.
	useBridge = true,
	bridgeUrl = "ws://localhost:8765",   -- or the robot laptop's LAN IP
	bridgeHelloSeconds = 3,              -- no hello by then at server start: fake generator for this session
	bridgeStaleSeconds = 1,              -- no frame, or blocks_age over this (or none yet): OFFLINE (matching freezes)
	staleBlockSeconds = 2,               -- a visible = false block (hidden by the arm) still counts until its age passes this
	-- Perception's color names for our six blocks -> Config.colors names (robot/perception/config.py
	-- BLOCK_COLORS). Any other name on a non-held block (green, blue, pink, white, black, grey, ...) is a
	-- misread: the LiveBoard draws it gray and compare counts it as a wrong block.
	perceptionColors = { red = "red", orange = "orange", yellow = "yellow", teal = "teal", purple = "purple",
	                     ["light blue"] = "skyblue" },
	-- Grid fallback. The hello frame's space.grid (origin_mm, cell_mm, rows, cols) replaces these on the
	-- server once the bridge says hello (Grid.setGeometry).
	gridCols = 4, gridRows = 3,          -- printed sheet: columns 1-4 (tag 0 -> tag 1), rows A-C (arm -> tripod)
	gridOriginMm = Vector2.new(25.4, 22.225), -- sheet mm of cell A1's outer corner (the corner nearest tag 0)
	cellSizeMm = 57.15,                  -- measured on the printed sheet
	flipX = false,                       -- true mirrors columns (1 <-> 4) if the sheet or tags turn out reversed
	flipY = false,                       -- true mirrors rows (A <-> C)
	cellTolerance = 0.7,
	maxStackGlobal = 2,                  -- hard cap on tower height; a block at level >= this always counts as extra
	ignoreZones = { tray = true },       -- block zones that never count (plan.md: the inventory tray maps to nothing)
	boardCellStuds = 4,                  -- studs per grid cell on the boards; with cellSizeMm this is the mm -> stud scale
	twinBaseOffsetMm = 90,               -- built arm twin's base center, from the grid's row A edge toward the operator
	twinStickMm = { link = 30, joint = 40, tip = 26, base = 80 }, -- stick-figure twin thicknesses (sheet mm)
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
	uniqueColorsPerTicket = false,       -- true: no color twice in one pattern (tickets and the attract demo),
	                                     --   towers included. Off since core perception names repeated colors
	                                     --   (robot/perception/naming.py); kept as a fallback
	stackChanceStart = 0.2,              -- chance a ticket block goes on top of another, ramping linearly over
	stackChanceEnd = 0.6,                --   the shift from start to end
	ticketTimeBonus = 3,                 -- seconds added to the shift timer per completed ticket
	ticketPoints = { ticket = 1, flat = 1, stacked = 3 }, -- per ticket, per level 0 block, per level 1 block
	holdToClear = 1,
	maxTimeBonus = 60,                   -- cap on the seconds ticket bonuses add to one shift (bounds Mode.MaxDuration)
	winPoints = 20,                      -- a shift scoring at least this is a WIN: +1 Win in the arcade
	-- The arcade mode (ServerStorage.Modes.PatternMatch): Start clones the Map into Workspace under this
	-- name, moved so its origin (where the bedroom was built) sits at mapOffset: clear of the Workshop
	-- (x 306..494, z 198..322), Rising Flood (x = 400) and the carnival village and terrain at negative x.
	mapName = "PatternMatchMap",
	mapOffset = Vector3.new(0, 0, -400),
	fakeArcade = false,                  -- testing (Studio only): ServerScriptService.FakeArcade builds a test
	                                     --   lobby with a pad that runs the mode like the arcade does
	attractEnabled = true,               -- Idle: demo loop on the boards (PatternMatch.Attract), while players
	                                     --   wait in the room before someone presses Play
	roomIdleSeconds = 90,                -- the arcade's Start puts players in the room (Idle); nobody presses
	                                     --   Play by then: the game ends, nobody wins
	attractPlaceInterval = 0.7,          -- seconds between the demo's block placements
	attractPatterns = 5,                 -- demo patterns per set before a fresh set is generated
	modeSelectSeconds = 15,
	modeConfirmSeconds = 1.5,            -- "HARD MODE" confirmation before the shift
	resultsSeconds = 10,
	debugAutoSolve = false,              -- testing (fake generator or the mock source): rebuilds the board for the active ticket 3 s after it becomes active
	debugFastTimers = false,             -- testing: every game timer (room wait, shift, ticket arrivals, reveal) runs 4x faster
	debugForceMode = nil,                -- testing: "easy" or "hard" makes ModeSelect pick that mode; nil picks Easy
	hard = { showSeconds = 5, hideSeconds = 5 }, -- Hard: the target's colors show, then hide, on repeat
	twinJoints = { shoulder_pan = {sign=1, offset=0}, shoulder_lift = {sign=1, offset=0}, elbow_flex = {sign=1, offset=0},
	               wrist_flex = {sign=1, offset=0}, wrist_roll = {sign=1, offset=0}, gripper = {sign=1, offset=0} },
	-- Arm twin's folded rest pose, shown while there is no arm data (no sample yet, an empty one, or none
	-- for ArmTwin.Driver's stale timeout) and used for any joint a sample leaves out. Same units as
	-- StateStore.arm (degrees, gripper 0..100) and run through twinJoints like a sample, so after tuning set
	-- it to what the real arm reports at rest. Upper arm up and leaning back, forearm folded forward, hand
	-- hanging just in front of the base: highest point ~16.2 studs above the base (elbow hub).
	twinRestPose = { shoulder_pan = 0, shoulder_lift = 125, elbow_flex = -128, wrist_flex = -76, wrist_roll = 0, gripper = 0 },
}
