-- ReplicatedStorage.PatternMatch.Config
-- Tunables for Pattern Match. See docs/pattern-match-v1.md section 8.

return {
	useFakeState = true,                 -- Core.StateStore stand-in invents blocks; set false once the real core is in
	gridCols = 4, gridRows = 3,
	gridOriginCm = Vector2.new(0, 0),   -- set with core guy: A1 corner nearest the arm, in table cm
	cellSizeCm = 6,                      -- set after measuring the printed grid
	cellTolerance = 0.7,
	-- Target generation only uses colors listed here. Remove an entry if vision can't separate it.
	colors = { purple = Color3.fromRGB(128,0,255), red = Color3.fromRGB(255,0,0), yellow = Color3.fromRGB(255,220,0),
	           orange = Color3.fromRGB(255,120,0), teal = Color3.fromRGB(0,160,160), skyblue = Color3.fromRGB(100,180,255) },
	blocksPerRound = { 3, 4, 5 },
	roundSeconds = { 60, 75, 90 },
	holdToClear = 1,
	intermissionSeconds = 10,
	modeSelectSeconds = 15,
	hard = { showSeconds = 5, hideSeconds = 5, eventEvery = 30 },
	easy = { eventEvery = 45 },
	vanishSeconds = 6, vanishCount = { 1, 2 },
	events = { "vanish", "tremor", "inverted" },
	twinJoints = { shoulder_pan = {sign=1, offset=0}, shoulder_lift = {sign=1, offset=0}, elbow_flex = {sign=1, offset=0},
	               wrist_flex = {sign=1, offset=0}, wrist_roll = {sign=1, offset=0}, gripper = {sign=1, offset=0} },
}
