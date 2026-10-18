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

return Config
