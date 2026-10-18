--!strict
-- Every colour and font in the Dragon Arena. Require this; do not write Color3 literals elsewhere.
--
-- This lives in ReplicatedStorage, not ServerScriptService, because the HUD is a LocalScript and
-- needs the same palette the server builds the world from. One source, both sides.
--
-- Two rules the rest of the mode leans on (style guide section 3 and hard rule 7):
--
-- Brightness order, brightest first: hazards (fire, shockwave, lava) -> power-ups and debuff
-- effects -> the dragon's eyes -> the dragon's body -> players -> environment. If something lower
-- on this list renders brighter than something higher, the scene stops reading.
--
-- Warm means dragon and danger; cool means players. Fire, lava, shockwaves and the dragon use
-- reds, oranges and yellows. Power-ups, player abilities and debuffs *on* the dragon use cyan,
-- aqua, violet, magenta, ice and lime. Never give a player effect a warm colour, and never give a
-- dragon attack a cool one. Theme.effectColor is the only place an effect name becomes a colour,
-- so that split cannot drift.

local Theme = {}

Theme.Color = {
	-- Environment: dark, low saturation, never orange
	-- Lifted from the style guide's swatches. The scene is lit almost entirely by lava, so these
	-- render far darker in game than they look here - at the guide's literal values the floor read
	-- as a black hole and you could not tell where you were standing. The brightness *order* in
	-- section 3 is what matters and is unchanged: these are still the dimmest things on screen.
	Obsidian     = Color3.fromRGB(68, 56, 58),    -- arena floor
	ObsidianDeep = Color3.fromRGB(34, 20, 22),    -- floor cracks, pits, crater centres
	Basalt       = Color3.fromRGB(92, 58, 62),    -- pillars, walls, platforms, boulders
	BasaltEdge   = Color3.fromRGB(132, 96, 97),   -- top bevels, so platform edges read

	-- Heat: the brightest things on screen
	Lava         = Color3.fromRGB(242, 98, 42),
	LavaHot      = Color3.fromRGB(251, 155, 58),  -- shockwave core, body of the fire
	WhiteHot     = Color3.fromRGB(255, 226, 154), -- core of the fire, impact flash
	Ember        = Color3.fromRGB(182, 77, 22),   -- trail tails, cooling craters
	Scorch       = Color3.fromRGB(30, 14, 12),    -- burn marks, smoke

	-- Dragon: mid brightness, warm
	DragonScale  = Color3.fromRGB(168, 40, 28),   -- main armour plates
	DragonShade  = Color3.fromRGB(96, 20, 17),    -- underside, plate edges, dormant body
	DragonSpike  = Color3.fromRGB(43, 10, 9),     -- spikes, horns
	DragonIron   = Color3.fromRGB(58, 52, 54),    -- joint rings, pedestal, bolts
	DragonTooth  = Color3.fromRGB(235, 220, 200),
	DragonEye    = Color3.fromRGB(255, 138, 31),  -- eyes and mouth glow (Neon)

	-- Player side: cool colours only
	Power        = Color3.fromRGB(110, 200, 255), -- generic pickup, "ready" glow, survivors win
	Shake        = Color3.fromRGB(0, 240, 200),   -- earthquake
	Slow         = Color3.fromRGB(124, 108, 255), -- molasses
	Inverted     = Color3.fromRGB(224, 64, 251),  -- mirror
	Frozen       = Color3.fromRGB(191, 239, 255), -- freeze
	Lag          = Color3.fromRGB(154, 166, 178), -- fog
	Jammed       = Color3.fromRGB(166, 226, 46),  -- butterfingers

	-- UI
	UiInk        = Color3.fromRGB(11, 7, 9),      -- panels at Transparency 0.35, text strokes
	UiText       = Color3.fromRGB(255, 255, 255),
	UiDanger     = Color3.fromRGB(255, 72, 56),   -- timer under 10 s, elimination flash
}

-- Lighting colours. These belong here for the same reason the part colours do (hard rule 6): they
-- set the whole scene's cast, and a tint nudged in Arena.lua while the palette stays put is how a
-- "dark volcanic" scene quietly turns brown. Starting values from the style guide, section 4 -
-- judge them in Play mode under the final lighting, not as swatches.
Theme.Lighting = {
	Ambient        = Color3.fromRGB(78, 52, 54),
	OutdoorAmbient = Color3.fromRGB(104, 68, 66),
	AtmosphereTint = Color3.fromRGB(120, 50, 40),
	AtmosphereDecay = Color3.fromRGB(60, 20, 25),
	GradeTint      = Color3.fromRGB(255, 240, 232),
}

-- Builder Sans ships with Roblox.
Theme.Font = {
	Display = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold),
	Label   = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
}

-- Effect name (as the protocol spells it) -> how it is shown. The protocol's `effects` list in the
-- hello frame is authoritative for *which* effects exist, so this table is looked up, never
-- iterated to build a UI: an effect the server grows that is missing here falls back to Power and
-- its own name, which is ugly but correct, rather than vanishing from the game.
-- The icon itself lives in Icons.lua, drawn from Frames rather than loaded from an asset id. See
-- that file for why: a wrong or unmoderated id renders as nothing, which looks exactly like a bug.
Theme.Effect = {
	earthquake    = { label = "SHAKE",      color = "Shake" },
	molasses      = { label = "SLOWED",     color = "Slow" },
	mirror        = { label = "INVERTED",   color = "Inverted" },
	freeze        = { label = "FROZEN",     color = "Frozen" },
	fog           = { label = "LAGGING",    color = "Lag" },
	butterfingers = { label = "JAW JAMMED", color = "Jammed" },
}

-- The one place an effect name becomes a colour. Unknown names get Power, which is cool - so an
-- effect nobody has themed yet still cannot come out warm and read as a dragon attack.
function Theme.effectColor(name: string): Color3
	local entry = Theme.Effect[name]
	return Theme.Color[entry and entry.color or "Power"]
end

function Theme.effectLabel(name: string): string
	local entry = Theme.Effect[name]
	return entry and entry.label or string.upper(name)
end

return Theme
