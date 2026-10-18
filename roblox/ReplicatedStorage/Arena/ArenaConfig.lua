--!strict
-- Every tunable number in the Dragon Arena, in one file so none of them hide in logic.
--
-- Two different kinds of number live here, and they are not equally trustworthy:
--
--   MEASURED  - comes from the real arm or the printed sheet. Changing it is a lie about the
--               hardware. There are almost none of these; the sheet size and the arm base arrive
--               in the `hello` frame at run time instead of being written down here.
--   GUESS     - a starting value the style guide marks as "tune in teleop". Every detection
--               threshold is one of these. Section 14 of the style guide lists how to measure
--               each. Do not treat a guess as settled because the demo happened to work once.
--
-- Gameplay numbers (round length, damage, pickup rate) are the designer's call, not the style
-- guide's. They live here so the designer can find them, with no visual code depending on them.

local ArenaConfig = {}

-- Detection: all GUESS. Set the speed thresholds from logged real slams, not by feel. The
-- follower caps how far it can move per tick (`max_relative_target = 10` in robot/arm.py), so its
-- top speed is bounded - a threshold above that can never fire.
ArenaConfig.ARENA_FLOOR_MM  = 25     -- real height above the paper that counts as the arena floor
ArenaConfig.SLAM_HEIGHT_MM  = 12     -- a tip this close to the floor counts as contact
ArenaConfig.SLAM_SPEED_MMS  = 200    -- minimum downward tip speed for a slam
ArenaConfig.SLAM_REARM_MM   = 60     -- the tip must rise this far before it can slam again
ArenaConfig.SLAM_RADIUS     = 35     -- studs the shockwave ring travels
ArenaConfig.SWEEP_HEIGHT_MM = 40     -- a tip this close to the floor counts as low
ArenaConfig.SWEEP_SPEED_MMS = 150    -- minimum sideways tip speed for a sweep
ArenaConfig.FIRE_OPEN_FRAC  = 0.7    -- share of the jaw's observed range that counts as open
ArenaConfig.FIRE_MIN_PCT    = 30     -- lowest gripper reading that can breathe fire
ArenaConfig.FIRE_RANGE      = 60     -- studs, length of the fire cone
ArenaConfig.FIRE_HALF_ANGLE = 18     -- degrees, half-angle of the fire cone
ArenaConfig.STALE_ARM_S     = 0.5    -- arm_age above this makes the dragon dormant

-- FIRE_MIN_PCT sits deliberately above BUTTERFINGERS_OPEN_PCT (18.0 in bridge/effects.py): that
-- debuff holds the jaw at least 18% open for its whole duration, and a fire test on the learned
-- range alone would read that jammed-open jaw as a roar and hand the dragon free fire for 8 s -
-- turning a player's power-up into a reward for the dragon. Raising the floor is not enough on its
-- own either, which is why AttackDetect requires both tests. See the style guide, section 7.
ArenaConfig.BUTTERFINGERS_FLOOR_PCT = 18.0

-- TESTING AGAINST `--source mock`.
--
-- The mock is not a toy: it drives the real IK and the real fitted calibration through a scripted
-- pick-carry-stack, eased with a cosine so peak speed is about 1.57x the average for each move.
-- Worked against that script, the shipped thresholds above mean:
--
--   Fire  - fires out of the box. The mock's jaw runs 20..50, so the learned span is 30, an open
--           jaw reads frac 1.0, and 50 is well above FIRE_MIN_PCT. It will be lit most of the
--           cycle, which is exactly what you want when checking the cone and the scorch marks.
--   Slam  - NEVER fires. The fastest descent ("lower on A1", 150 -> 18 mm in 1.0 s) is down to
--           about 145 mm/s by the time it crosses the slam height, because the ease is already
--           slowing it. That is below SLAM_SPEED_MMS, so nothing triggers.
--   Sweep - NEVER fires, at any speed threshold. The mock only moves sideways at carry height
--           (150 mm), and only moves vertically when it is low, so "low AND moving sideways" is
--           never true. The height gate has to move, not just the speed gate.
--
-- So a mock run that shows fire but no slams and no sweeps is CORRECT, not broken. To see all
-- three, use these while testing against mock, and put the real values back before tuning against
-- the arm - they are chosen to catch the mock's motion, not to describe a dragon:
--
--   ArenaConfig.SLAM_SPEED_MMS  = 100   -- mock peaks ~145 mm/s below the slam height
--   ArenaConfig.SWEEP_HEIGHT_MM = 130   -- so carry height (150 mm) counts as "low"
--   ArenaConfig.SWEEP_SPEED_MMS = 90    -- mock's lateral peak is ~129 mm/s
--
-- Note the mock's grasp height (14 mm) is below ARENA_FLOOR_MM, so the head dips a few studs
-- through the arena floor at the bottom of a pick. That is the floor being above the real table,
-- working as designed, not a rig bug.

-- Velocity is differentiated from each frame's `ts`, never from Heartbeat's delta time: Bridge
-- keeps only the newest frame and drops the rest, so Heartbeat's dt and the gap between the frames
-- actually seen are different numbers. Smoothing spans a few frames so one jittery FK sample
-- cannot read as a slam.
ArenaConfig.VELOCITY_SMOOTH_FRAMES = 3
ArenaConfig.VELOCITY_MAX_GAP_S = 0.5  -- a longer gap than this restarts the estimate rather than
                                      -- dividing a large move by a large dt and inventing speed

-- The jaw's range is learned as the arm runs, the same way bridge/world.py `_grip_state` does,
-- because what counts as "open" depends on the gripper and its calibration. A hardcoded percentage
-- that is wrong for this arm makes the jaw read as permanently shut, and the dragon never breathes.
-- Until the observed span is this wide, fall back to the fixed percentage.
ArenaConfig.GRIP_SPAN_MIN = 15.0
ArenaConfig.GRIP_OPEN_PCT = 35.0      -- fallback "open" reading before the span is known
ArenaConfig.JAW_MAX_DEG = 40          -- lower jaw angle at fully open; 35-45 reads as a roar

-- Dragon build. Thickness is in studs, at the shipped STUDS_PER_MM of 0.46.
ArenaConfig.SEGMENT_THICKNESS = { 16, 14, 12, 11, 12 }   -- shoulders, lower neck, upper neck, skull, head
ArenaConfig.PART_BUDGET = 80          -- the whole dragon; boxes, wedges and cylinders are fine

-- Arena. The floor is the printed sheet: that rectangle is what is physically in front of the arm,
-- and its size arrives in `hello.space.sheet` rather than being written here. The pedestal goes at
-- `hello.space.arm_base_mm`, which is off the top edge of the sheet - so the dragon already sits at
-- the back with the floor fanning out in front of it, with nothing guessed.
--
-- The style guide (section 5) asks for the floor to be the arm's measured *reach* outline instead.
-- Nobody has logged that yet, and the sheet is the honest stand-in: it is the real work surface,
-- and every block the game knows about is on it. When the reach is logged, the outline replaces
-- this rectangle and nothing else in the mode has to change - Arena.lua is the only file that
-- knows the floor's shape.
ArenaConfig.ARENA_MARGIN_MM = 12      -- floor extends this far past the sheet, left/right/far
ArenaConfig.LAVA_WIDTH_MM = 220       -- the lava moat ringing the floor
ArenaConfig.CLIFF_HEIGHT = 90         -- studs, the back wall the pedestal is set against

-- How much of the sheet to actually play on, 0..1. The floor is anchored at the dragon's end and
-- shrinks toward it, so the pedestal stays against the back cliff and the far edge comes closer.
--
-- Shrinking is always safe in the direction that matters: a smaller floor is more reachable, never
-- less, so it cannot create the thing the style guide forbids - a spot the dragon cannot hit.
-- Growing it past 1.0 is the dangerous direction and is why this is capped in Arena.floorFromSheet.
-- Turn it down if the arena feels empty or the dragon cannot cover the ground.
ArenaConfig.ARENA_SCALE = 0.68
ArenaConfig.ARENA_WIDTH_SCALE = 0.78  -- the same, across the sheet rather than away from the arm

-- Where the arena sits in the arcade place: the floor's centre, its top surface at this Y. Clear of
-- the Workshop (x 306..494, z 198..322), Rising Flood at (400, 0, 0), Pattern Match at (0, 0, -400) and
-- the carnival village's hill and buildings (x < -114, z < 330). The whole build (lava ring, cliff,
-- spires, gallery) spans roughly 180 studs either side of it in X and Z.
ArenaConfig.CENTER = Vector3.new(0, 0, 700)

-- Round flow. The designer's numbers. One round per arcade game: intro, countdown, the round, then
-- the result banner, and Finished goes to the arcade.
ArenaConfig.INTRO_SECONDS = 4         -- players on their spots, the lobby pad on, before the countdown
ArenaConfig.COUNTDOWN_SECONDS = 3
ArenaConfig.ROUND_SECONDS = 120
ArenaConfig.RESULT_SECONDS = 5        -- SURVIVORS WIN / THE DRAGON WINS on screen before Finished
ArenaConfig.MAX_DURATION_MARGIN = 20  -- Module.MaxDuration = all of the above plus this
ArenaConfig.MAX_PLAYERS = 12

-- Spawning. Characters are 1.5x in the arcade (ServerScriptService.CharacterScale), about 7.5 studs
-- tall and 3 wide, so spots are a body and a half apart.
ArenaConfig.SPAWN_SPACING = 9         -- studs between spawn spots (and gallery spots)
ArenaConfig.SPAWN_FRAC = 0.84         -- how far down the floor the front spawn row is, 0 = the dragon's end
ArenaConfig.PAD_FRAC = 0.93           -- the lobby pad, same measure: the front edge of the floor
ArenaConfig.PAD_SIZE = 9              -- studs across
ArenaConfig.GALLERY_HEIGHT = 30       -- studs above the floor: the eliminated watch from here
ArenaConfig.GALLERY_SIZE = Vector2.new(64, 16) -- studs, across x deep

-- With no robot hello (the core's fake generator, or no robot yet) there is no effects list to
-- build pickups from. These are the effects bridge/effects.py has; firing one with no robot hands
-- the slot back (Pickups.fireSlot), so the crystals still show and nothing is lost.
ArenaConfig.DEFAULT_EFFECTS = { "butterfingers", "earthquake", "fog", "freeze", "mirror", "molasses" }

-- Damage. A hit kills outright: the dragon is 8-10x a player's height and the fantasy is dodging,
-- not trading blows. Changing this to a health model is a design decision, not a visual one.
ArenaConfig.SLAM_KNOCKBACK = 120      -- studs/s imparted by the shockwave ring
ArenaConfig.SWEEP_KNOCKBACK = 160     -- studs/s imparted along the tip's sideways velocity
ArenaConfig.HIT_GRACE_S = 0.6         -- a player cannot be hit twice inside this window

-- Pickups. A crystal fills a free ability slot; the player fires it when they choose.
ArenaConfig.PICKUP_INTERVAL_S = 8
ArenaConfig.PICKUP_MAX_ALIVE = 4
ArenaConfig.ABILITY_SLOTS = 4
ArenaConfig.ABILITY_COOLDOWN_S = 3    -- after firing a slot, before that slot can refill

-- What a player's power-up asks the arm for. Duration is clamped server-side by bridge/effects.py
-- LIMITS, so these are requests, not guarantees - the HUD reads back `state.effects[].remaining`
-- for the true value. Asking for more than the cap is harmless and is how the mode says "max".
ArenaConfig.EFFECT_REQUEST = {
	earthquake    = { intensity = 0.8, duration = 5 },
	molasses      = { intensity = 0.9, duration = 10 },
	mirror        = { intensity = 1.0, duration = 15 },
	freeze        = { intensity = 1.0, duration = 3 },
	fog           = { intensity = 0.7, duration = 10 },
	butterfingers = { intensity = 1.0, duration = 8 },
}

-- The aerial operator camera. Height and setback are fractions of the floor's own size, so they
-- stay sensible when ARENA_SCALE changes. Lower HEIGHT to come in closer; raise BACK to sit
-- further behind the dragon and see more of what is in front of it.
ArenaConfig.AERIAL_HEIGHT_FRAC = 0.62
ArenaConfig.AERIAL_BACK_FRAC = 0.38
ArenaConfig.AERIAL_FOV = 55           -- degrees; lower zooms in without moving the camera

-- The operator's aiming aids, drawn on the aerial view only.
--
-- These do not break hard rule 1. That rule forbids telegraphs on the PLAYERS' screens, because
-- players must dodge by watching the dragon rather than reading a marker that says where the next
-- strike lands. The operator's problem is the opposite one and is not about fairness at all: they
-- are flying a real 3D arm from a flat overhead view, where "directly above you" and "thirty studs
-- short" look identical, so without a height cue they are aiming blind. What is drawn here is the
-- arm's CURRENT position - the same class of thing as the dragon's own shadow, which rule 1
-- explicitly allows - and it is built on the operator's client, so no player ever sees it.
ArenaConfig.AIM_RETICLE_RADIUS = 14   -- studs; inside this counts as "over" a player
ArenaConfig.AIM_SHOW = true           -- false strips the aids back to a bare overhead camera

-- Lighting levels, separate from the colours in Theme. The style guide asks for a dark arena lit
-- almost entirely by lava, and these are the knobs for deciding how far to take that. Dark enough
-- that the fire reads, bright enough to see the dragon's armour and where you are standing.
-- In the arcade nothing may set Lighting (the arcade owns it): the views build what they can of
-- this look on the client, as effects under the camera (ReplicatedStorage.Arena.Client), and the
-- rest (Brightness, exposure, ambient, atmosphere, sky) cannot be reproduced there.
ArenaConfig.LIGHTING = {
	Brightness = 2.6,
	ExposureCompensation = 0.35,
	EnvironmentDiffuseScale = 0.55,
	EnvironmentSpecularScale = 0.7,
	AtmosphereDensity = 0.2,
	AtmosphereHaze = 0.8,
	AtmosphereGlare = 0.15,
	BloomIntensity = 0.85,
	BloomThreshold = 1.6,
	Contrast = 0.08,
	Saturation = 0.06,
}

-- Performance budget (style guide section 12). The effect modules check themselves against these.
ArenaConfig.MAX_IMPACT_MARKS = 20
ArenaConfig.MAX_ENV_POINT_LIGHTS = 8
ArenaConfig.IMPACT_MARK_LIFETIME_S = 30
ArenaConfig.IMPACT_MARK_COOL_S = 3    -- Ember rim fades to Scorch over this

return ArenaConfig
