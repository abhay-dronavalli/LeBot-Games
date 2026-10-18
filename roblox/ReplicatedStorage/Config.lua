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

return Config
