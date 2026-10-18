local Config = {}

Config.DebugMode = true

-- Grid / world layout (Section 7)
Config.CellSize = 8        -- studs per cell, square
Config.BayCols = 4         -- columns (X), 0-3
Config.BayRows = 3         -- rows (Z), 0-2, row 0 nearest the bay entrance
Config.BayGap = 6          -- catwalk studs between bays
Config.BayWidth = Config.CellSize * Config.BayCols   -- 32
Config.BayDepth = Config.CellSize * Config.BayRows   -- 24
Config.BayPitch = Config.BayDepth + Config.BayGap    -- 30, Z distance from one bay's start to the next
Config.NumBays = 9

-- Transport (Section 7, 12)
Config.PollRateHz = 3.5
Config.WebSocketHz = 25
Config.StaleAfterSeconds = 2

-- Units -- Open Item #1 (Section 20), unconfirmed with the robot teammate
Config.StudsPerCm = 1
Config.ArmAngleUnits = "degrees"

-- Clocks (Section 6) -- placeholders, retune after measuring real placement speed (Section 15, T+13-17)
Config.FullRunSeconds = 8 * 60
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
Config.SawWallSeconds = 60
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
Config.LaserCooldownSeconds = 6     -- how long the vacated cell stays safe once the crate lands
Config.LaserRearmWarnSeconds = 1.5  -- the pad pulses fast for this long before the beams return
Config.LaserRouteMin = 6            -- steps in a generated route, inclusive
Config.LaserRouteMax = 8

-- Full playspace shell (Section 3.1, 7)
Config.EntranceBuffer = 10   -- buffer studs before Bay 1, holds the spawn
Config.FinaleBuffer = 10     -- buffer studs after Bay 9, holds the finale area
Config.WallHeight = 28   -- tall enough that the gantry doesn't feel cramped overhead
Config.GantryHeight = 18 -- where the SkyArm rails/trolley ride; kept well below the ceiling
-- so there's open air above the arm. Deliberately separate from WallHeight: room height and
-- gantry height are different concerns, and the arm's reach math depends only on this one.
Config.SideMargin = 6   -- aisle space between the bay floor edge and the outer wall, for pallet racks
Config.WarehouseLength = (Config.NumBays - 1) * Config.BayPitch + Config.BayDepth

return Config
