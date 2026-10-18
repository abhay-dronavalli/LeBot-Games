--!strict
-- The power-up icons, drawn from plain Frames rather than loaded from the asset library.
--
-- WHY NOT IMAGES. An icon asset has to be uploaded, moderated and referenced by id, and an id that
-- is wrong or not yet approved renders as nothing - a blank slot that looks exactly like a bug.
-- Writing a made-up `rbxassetid` is worse still: it either fails silently or shows whatever that
-- number happens to point at. Frames always render, cost nothing, and take the effect's colour, so
-- the palette rule holds for free: these are player-side, so they come out cool.
--
-- They are deliberately chunky and geometric, which is the same language as the arena's parts.
-- Each one is built from rotated bars and rounded squares inside a square container, sized in
-- Scale so one definition serves a 64 px HUD slot and a pickup's billboard alike.
--
--   Icons.draw(someFrame, "freeze", Theme.Color.Frozen)
--
-- The same icon goes on the pickup in the world and in the slot it fills, which is what makes a
-- crystal you ran across the arena for recognisable when it lands in your bar.

local Icons = {}

local function bar(parent: Instance, color: Color3, x: number, y: number, w: number, h: number,
	rot: number, round: number?): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(w, h)
	f.Rotation = rot
	f.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(round or 0.35, 0)
	c.Parent = f
	return f
end

local function dot(parent: Instance, color: Color3, x: number, y: number, d: number): Frame
	return bar(parent, color, x, y, d, d, 0, 0.5)
end

-- One builder per effect. Keyed by the protocol's own names.
local Draw = {}

-- SHAKE: a jolt. Three bars stepping across at alternating angles.
function Draw.earthquake(p: Instance, c: Color3)
	bar(p, c, 0.32, 0.30, 0.34, 0.12, 32)
	bar(p, c, 0.50, 0.50, 0.34, 0.12, -32)
	bar(p, c, 0.68, 0.70, 0.34, 0.12, 32)
end

-- SLOWED: a falling drop. A round body with a tapered cap above it.
function Draw.molasses(p: Instance, c: Color3)
	dot(p, c, 0.5, 0.62, 0.46)
	bar(p, c, 0.5, 0.30, 0.26, 0.26, 45, 0.25)
end

-- INVERTED: two chevrons pointing into each other across a centre line.
function Draw.mirror(p: Instance, c: Color3)
	bar(p, c, 0.5, 0.5, 0.07, 0.72, 0, 0.5)
	bar(p, c, 0.26, 0.38, 0.09, 0.30, 42)
	bar(p, c, 0.26, 0.62, 0.09, 0.30, -42)
	bar(p, c, 0.74, 0.38, 0.09, 0.30, -42)
	bar(p, c, 0.74, 0.62, 0.09, 0.30, 42)
end

-- FROZEN: a six-pointed star, three bars through the centre.
function Draw.freeze(p: Instance, c: Color3)
	bar(p, c, 0.5, 0.5, 0.10, 0.78, 0, 0.5)
	bar(p, c, 0.5, 0.5, 0.10, 0.78, 60, 0.5)
	bar(p, c, 0.5, 0.5, 0.10, 0.78, 120, 0.5)
end

-- LAGGING: banks of fog, three bars of uneven width.
function Draw.fog(p: Instance, c: Color3)
	bar(p, c, 0.46, 0.32, 0.62, 0.13, 0, 0.5)
	bar(p, c, 0.56, 0.52, 0.52, 0.13, 0, 0.5)
	bar(p, c, 0.44, 0.72, 0.66, 0.13, 0, 0.5)
end

-- JAW JAMMED: a boulder wedged between two jaw plates.
function Draw.butterfingers(p: Instance, c: Color3)
	bar(p, c, 0.5, 0.20, 0.72, 0.12, 0, 0.3)
	bar(p, c, 0.5, 0.80, 0.72, 0.12, 0, 0.3)
	bar(p, c, 0.5, 0.50, 0.40, 0.34, 12, 0.3)
end

-- Anything unthemed, including an effect Python grows that nobody has drawn yet: a plain pickup
-- diamond. Still legible, still the right colour, obviously generic.
local function generic(p: Instance, c: Color3)
	bar(p, c, 0.5, 0.5, 0.44, 0.44, 45, 0.18)
end

-- Draws `name` into `parent`, clearing whatever was there. Returns the square container it used,
-- so a caller can hide or re-tint the whole icon in one go.
function Icons.draw(parent: Instance, name: string, color: Color3): Frame
	local existing = parent:FindFirstChild("Icon")
	if existing then
		existing:Destroy()
	end

	local box = Instance.new("Frame")
	box.Name = "Icon"
	box.BackgroundTransparency = 1
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(0.5, 0.44)
	box.Size = UDim2.fromScale(0.62, 0.62)
	box.Parent = parent

	-- Square, whatever shape the slot is. Without this an icon in a wide chip shears into a
	-- rectangle and the snowflake stops being a snowflake.
	local ratio = Instance.new("UIAspectRatioConstraint")
	ratio.AspectRatio = 1
	ratio.Parent = box;

	(Draw[name] or generic)(box, color)
	return box
end

return Icons
