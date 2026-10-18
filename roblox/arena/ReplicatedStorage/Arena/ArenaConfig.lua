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
ArenaConfig.ARENA_MARGIN_MM = 40      -- floor extends this far past the sheet on all four sides
ArenaConfig.LAVA_WIDTH_MM = 220       -- the lava moat ringing the floor
ArenaConfig.CLIFF_HEIGHT = 90         -- studs, the back wall the pedestal is set against

-- Round flow. The designer's numbers.
ArenaConfig.ROUND_SECONDS = 120
ArenaConfig.INTERMISSION_SECONDS = 12
ArenaConfig.COUNTDOWN_SECONDS = 3
ArenaConfig.MIN_PLAYERS = 1
ArenaConfig.MAX_PLAYERS = 12

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

-- Performance budget (style guide section 12). The effect modules check themselves against these.
ArenaConfig.MAX_IMPACT_MARKS = 20
ArenaConfig.MAX_ENV_POINT_LIGHTS = 8
ArenaConfig.IMPACT_MARK_LIFETIME_S = 30
ArenaConfig.IMPACT_MARK_COOL_S = 3    -- Ember rim fades to Scorch over this

return ArenaConfig
