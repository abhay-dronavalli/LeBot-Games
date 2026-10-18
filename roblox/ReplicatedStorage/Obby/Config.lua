-- ReplicatedStorage.Obby.Config (ModuleScript) -- every Robo Obby tunable, read by the server modules
-- (ServerStorage.Modes.Obby.Server) and the client views (ReplicatedStorage.Obby.Views).
-- Arcade copy of lebot_obby/ReplicatedStorage/Config.lua: same values, plus the ARCADE block below.
local Config = {}

-- TWO MODES, and exactly one of them owns the crates at a time (robot-link.md).
--
--   "solo"  one player doing both jobs. You place blocks on the on-screen 4x3 grid and the
--           Sky Arm carries them in, so you are the operator as well as the runner. Nothing
--           is connected and nothing is scripted.
--   "live"  the real SO-101 on the other end of the socket. Your hands are the only thing
--           that places a block.
--
-- There is deliberately no third "play back a recording" mode. A feed that places blocks by
-- itself is indistinguishable from the game doing it, which is alarming and was.
-- In the arcade this is only the fallback: Module.Start picks "live" when the core robot link is up
-- (ServerStorage.Shared.Bridge.isOnline(), status "live" or "mock") and "solo" otherwise, once per
-- round. The obby never opens a socket of its own; the core's ServerScriptService.Bridge is the link.
Config.FeedMode = "solo"
-- Which bay the mat currently maps to. Hardcoded until ActiveBayTracker picks it from where
-- player 1 is standing -- that module is what makes one physical mat serve nine bays.
Config.LiveBay = 1

-- How the real arm is drawn. "gantry" is the Sky Arm proper: it hangs from the ceiling rails,
-- slides along the roof between bays, and is sized to the room. The real arm drives it by the
-- tip, so it reaches where the real arm reaches.
-- "mirror" is the literal stick-figure mirror -- joint for joint, true SO-101 proportions. It
-- is honest but it is a 43 stud tower that stands at the door and pokes through the roof,
-- which needs WallHeight ~50 and BayGap >= 12 to house (robot-link.md section 4).
Config.ArmStyle = "gantry"

----------------------------------------------------------------
-- ARCADE (docs/obby-mode-plan.md)
----------------------------------------------------------------
-- The course is built around bay 1 starting at Z = 0 and X running 0..32. In the arcade the whole map
-- (Warehouse + Backdrop) is baked OriginZ studs down +Z, clear of Pattern Match (Z -400), Flood
-- (X 400) and Dragon Arena (Z ~520..880): the hall spans Z ~1036..1284. A pure Z shift, so every Z
-- the code computes goes through RunControl.bayZStart / HazardManager's bayZStart and X needs nothing.
Config.OriginZ = 1100

-- Debug tools: the F1/F2 debug menu (F2 = full reset), Q ghost flight, the cell editor's hotkeys
-- (1-9 N T K H M R; R rebuilds every bay) and the DebugCommand remote. The arcade runs in Studio
-- (the robot socket only works there), so RunService:IsStudio() is always true and cannot gate
-- them: this flag does. The attribute ArcadeDebug = true on ServerStorage.Modes.Obby also turns it
-- on for a session without editing this file. Keep it false for anyone playing.
Config.ArcadeDebug = false

-- The run clock (the win condition): reach the Finish zone past bay 4 before it runs out.
-- FullRunSeconds (below) is the clock; the arcade's Mode.MaxDuration is 500 (clock + result screen
-- + slack). ResultSeconds is how long the win/lose screen shows before the arcade takes everyone back.
Config.ResultSeconds = 4

-- Character size. The course was built and tuned around 1.0 characters (lever stand levels, the laser
-- walk's beam heights, the void's gap), and the arcade grows everyone to 1.5x (ServerScriptService.
-- CharacterScale). So runners are shrunk to RunnerScale for the round -- on Start and on every respawn,
-- re-checked every 0.25 s because CharacterScale grows a new character only once its appearance has
-- loaded -- and given ArcadeScale back on Stop and when they take the Back to Lobby pad.
-- ArcadeScale must match CharacterScale's SCALE.
Config.RunnerScale = 1
Config.ArcadeScale = 1.5

-- A dead runner comes back at the approach to the furthest bay they have reached (that bay is rebuilt
-- fresh, like the debug menu's "start run"). Seconds after CharacterAdded before the teleport (the
-- runner is shrunk back to RunnerScale first).
Config.RespawnSettleSeconds = 0.6

-- The dark room without touching Lighting (the arcade owns it): HazardManager sets the attribute
-- Dark = true on the bay model, and the runner's client (Views.Player.DarkRoom) puts a
-- ColorCorrectionEffect under its own camera while it stands in that bay. Tune by eye in Play.
Config.DarkTint = Color3.fromRGB(46, 50, 74)
Config.DarkBrightness = -0.12
Config.DarkContrast = 0.35
Config.DarkSaturation = -0.45

-- Grid / world layout (Section 7)
Config.CellSize = 8        -- studs per cell, square
Config.BayCols = 4         -- columns (X), 0-3
Config.BayRows = 3         -- rows (Z), 0-2, row 0 nearest the bay entrance
Config.BayGap = 6          -- catwalk studs between bays
Config.BayWidth = Config.CellSize * Config.BayCols   -- 32
Config.BayDepth = Config.CellSize * Config.BayRows   -- 24
Config.BayPitch = Config.BayDepth + Config.BayGap    -- 30, Z distance from one bay's start to the next
-- SCOPE: four obstacles -- Saw, Void, LaserWalk, DarkZone. BayData keeps the rest past this
-- index so nothing builds them. Raise this and re-run build/scope_course.lua to bring the
-- parked bays and their geometry back.
Config.NumBays = 4

-- Transport (Section 7, 12)
Config.PollRateHz = 3.5
Config.WebSocketHz = 25
Config.StaleAfterSeconds = 2

-- Units -- Open Item #1 (Section 20), unconfirmed with the robot teammate
Config.StudsPerCm = 1
Config.ArmAngleUnits = "degrees"

-- Clocks (Section 6) -- placeholders, retune after measuring real placement speed (Section 15, T+13-17)
Config.FullRunSeconds = 8 * 60 -- the arcade run clock (Module)
Config.DemoRunSeconds = 2 * 60 + 30
Config.DeathPenaltySeconds = 10
Config.TealL1BonusSeconds = 3
Config.TealL2FreezeSeconds = 8

-- Malfunctions (Section 9)
Config.MalfunctionIntensity = 1
Config.MalfunctionTelegraphSeconds = 1.5
Config.MalfunctionCooldownSeconds = 10
Config.MalfunctionGraceAfterBayChange = 3

-- Crate resolution timing (Section 5.2)
Config.CrateConfirmDelay = 0.2
Config.CrateRemoveDelay = 0.4

-- Bay 1 saw wall -- the closing wall IS this obstacle's clock, so this single number sets the
-- whole bay's difficulty. Budget check: one reachAndPlace is ~5.5s of arm animation and the job
-- queue serializes them, so this bay's three placements cost ~17s before the player has climbed
-- anything. 30 played too fast once the no-place band went in, since stalling is no longer
-- available to buy that time back.
-- 60 -> 75: the wall is no longer vaultable, so every crossing has to be earned by
-- actually solving it, and the extra 15 s is the room that costs.
Config.SawWallSeconds = 75
Config.SawWallBrakeEnabled = true

-- You cannot drop a crate in front of live blades to stall the wall: a cell within this many
-- studs of the blades, or already past them, refuses the placement outright. Stalling only
-- becomes possible once Lever A has killed the blades, which is what makes the spare cube a
-- reward for finishing Lever A rather than a way to skip it.
Config.SawWallNoPlaceBand = 4

-- How long one crate holds the wall once the blades are dead. A stall is spent per crate, so
-- the spare cube buys a second one -- but a jammed crate is only ever a reprieve, never a
-- permanent shield, and the wall resumes full speed when the timer runs out.
Config.SawWallStallSeconds = 10

Config.SawLeverHoldSeconds = 1 -- how long E is held to throw a lever

-- Bay 2 void -- the shaft is presentation plus a kill plane; the obstacle is the gap itself,
-- and that is sized by BayData[2].coverRows, not from here. Worth writing down why no tunable
-- is needed for the width: rows 0-1 span 16 studs and a running jump covers 8.67 (stock
-- JumpHeight 7.2, WalkSpeed 16, Gravity 196.2), so one row of void is already unjumpable and
-- two is well clear of it.
Config.VoidShaftDepth = 48    -- studs from floor level down to the kill plane
Config.VoidLightSpacing = 14  -- spacing of the red warning lights going down the shaft

-- Bay 3 laser walk -- one crate walked ahead of the player across a lethal grid.
--
-- The cooldown is counted from the moment the crate SEATS in its new cell, not from when it
-- was lifted, which is what lets this number be about the player's hop instead of the arm's
-- speed: one reachAndPlace is ~5.5s and a move is a remove plus a place, so a cooldown started
-- at lift would be gone before the crate even landed.
-- 6 was not enough to move a real cube and then walk the step. Swapping a block is a physical
-- action on a physical table, and the clock does not start until the NEW tile is live.
Config.LaserCooldownSeconds = 10    -- how long the vacated cell stays safe once the crate lands
Config.LaserRearmWarnSeconds = 2    -- the pad pulses fast, and counts in tenths, for this long
Config.LaserRouteMin = 6            -- steps in a generated route, inclusive
Config.LaserRouteMax = 8

-- Full playspace shell (Section 3.1, 7)
Config.EntranceBuffer = 10   -- buffer studs before Bay 1, holds the spawn
Config.FinaleBuffer = 10     -- buffer studs after Bay 9, holds the finale area
-- Raised from 28. Purely the room: nothing reads WallHeight at runtime, it records what the
-- baked geometry is -- so changing it means re-running build/fit_shell.lua, which is what
-- makes the shell follow it again.
Config.WallHeight = 48
Config.GantryHeight = 18 -- where the SkyArm rails/trolley ride; kept well below the ceiling
-- so there's open air above the arm. Deliberately separate from WallHeight: room height and
-- gantry height are different concerns, and the arm's reach math depends only on this one.
Config.SideMargin = 6   -- aisle space between the bay floor edge and the outer wall, for pallet racks
Config.WarehouseLength = (Config.NumBays - 1) * Config.BayPitch + Config.BayDepth

return Config
