-- UiTheme -- one steampunk look, shared by every screen in the game.
--
-- Before this, each client script invented its own panel: three different dark-grey
-- rectangles, three different fonts, three different ideas of what "danger red" is. The HUD
-- read like three separate debug tools stacked on one screen, because that is what it was.
--
-- THE LOOK: riveted iron plate, brass framing, amber gaslight text. Everything is built from
-- Frames and UIStrokes -- no images, no uploaded assets -- so it reproduces from source like
-- the rest of the environment does.
--
-- USAGE
--   local Ui = require(ReplicatedStorage.UiTheme)
--   local panel = Ui.panel({parent = gui, size = UDim2.fromOffset(460, 150)})
--   Ui.text(panel.body, {text = "FIND THE SCREWS", style = "task", tone = "danger"})
--
-- `panel()` returns {frame, body, header, setHeader, setTone}. Put content in `.body`, which
-- is already inset past the frame's rivets -- parenting straight to `.frame` will put your
-- label underneath them.

local UiTheme = {}

----------------------------------------------------------------
-- Palette
----------------------------------------------------------------
-- Pulled from the same places the world is: the hall's brass and copper, the gas lamps'
-- amber, the teal patina on the pipework, and the furnace red the void glows with. The HUD
-- sitting in the same palette as the room is most of what makes it feel built rather than
-- bolted on.
UiTheme.C = {
	iron       = Color3.fromRGB(26, 21, 18),   -- panel body
	ironLight  = Color3.fromRGB(41, 34, 29),   -- raised areas, header band
	ironDark   = Color3.fromRGB(14, 11, 9),    -- insets, grid cells
	brass      = Color3.fromRGB(176, 141, 74), -- framing, rivets, rules
	brassDim   = Color3.fromRGB(110, 86, 44),  -- inactive framing
	copper     = Color3.fromRGB(168, 95, 51),
	patina     = Color3.fromRGB(62, 107, 99),

	amber      = Color3.fromRGB(255, 196, 110), -- primary text, gaslight
	parchment  = Color3.fromRGB(238, 226, 206), -- body text
	faded      = Color3.fromRGB(150, 134, 114), -- secondary text
	ghost      = Color3.fromRGB(96, 85, 72),    -- disabled / done

	danger     = Color3.fromRGB(232, 85, 47),   -- furnace red
	warn       = Color3.fromRGB(240, 170, 60),
	ok         = Color3.fromRGB(111, 207, 143), -- patina green
	info       = Color3.fromRGB(120, 186, 214),
}

-- Tone names are the server's vocabulary (`tone = "danger"` in an objective payload), so the
-- mapping lives here rather than being re-declared by every consumer.
UiTheme.TONE = {
	danger = UiTheme.C.danger,
	warn = UiTheme.C.warn,
	ok = UiTheme.C.ok,
	info = UiTheme.C.info,
}

function UiTheme.tone(name, fallback)
	return UiTheme.TONE[name] or fallback or UiTheme.C.danger
end

----------------------------------------------------------------
-- Type
----------------------------------------------------------------
-- Antique is the Victorian signage face and carries the whole theme; Oswald is condensed
-- industrial lettering for anything that has to be read at a glance across a room; Merriweather
-- is the only one of the three comfortable in a paragraph.
UiTheme.F = {
	title = Enum.Font.Antique,
	task = Enum.Font.Oswald,
	number = Enum.Font.Oswald,
	body = Enum.Font.Merriweather,
	label = Enum.Font.GothamBold,
}

local STYLE = {
	-- style name -> {font, size, colour, alignment}
	title   = {UiTheme.F.title,  15, UiTheme.C.brass,     Enum.TextXAlignment.Center},
	task    = {UiTheme.F.task,   27, UiTheme.C.amber,     Enum.TextXAlignment.Center},
	hint    = {UiTheme.F.body,   13, UiTheme.C.faded,     Enum.TextXAlignment.Center},
	step    = {UiTheme.F.body,   13, UiTheme.C.parchment, Enum.TextXAlignment.Left},
	note    = {UiTheme.F.body,   12, UiTheme.C.faded,     Enum.TextXAlignment.Center},
	caption = {UiTheme.F.label,  11, UiTheme.C.faded,     Enum.TextXAlignment.Left},
	label   = {UiTheme.F.label,  12, UiTheme.C.parchment, Enum.TextXAlignment.Center},
	number  = {UiTheme.F.number, 30, UiTheme.C.parchment, Enum.TextXAlignment.Center},
	big     = {UiTheme.F.title,  34, UiTheme.C.amber,     Enum.TextXAlignment.Center},
}

----------------------------------------------------------------
-- Pieces
----------------------------------------------------------------
local function stroke(inst, colour, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = colour
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end
UiTheme.stroke = stroke

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 4)
	c.Parent = inst
	return c
end
UiTheme.corner = corner

-- A single brass rivet. Small enough to read as a detail rather than a dot.
function UiTheme.rivet(parent, anchor, pos)
	local r = Instance.new("Frame")
	r.Name = "Rivet"
	r.AnchorPoint = anchor
	r.Position = pos
	r.Size = UDim2.fromOffset(5, 5)
	r.BackgroundColor3 = UiTheme.C.brass
	r.BorderSizePixel = 0
	r.ZIndex = 6
	r.Parent = parent
	corner(r, 3)
	-- a darker underside sells it as domed rather than flat
	local shade = Instance.new("Frame")
	shade.AnchorPoint = Vector2.new(0.5, 1)
	shade.Position = UDim2.new(0.5, 0, 1, 0)
	shade.Size = UDim2.fromOffset(5, 2)
	shade.BackgroundColor3 = UiTheme.C.brassDim
	shade.BorderSizePixel = 0
	shade.ZIndex = 6
	shade.Parent = r
	corner(shade, 2)
	return r
end

-- Rivets marching along the top and bottom edges of a panel.
function UiTheme.rivetRow(frame, inset, spacing)
	-- A rivet is a child Frame, and a child Frame inside a laid-out container is a LIST ITEM.
	-- Called on a UIListLayout panel, this marches rivets down the left edge as rows and
	-- shoves every real control out of position -- which is exactly what it did to the debug
	-- menu. Refuse rather than quietly wreck the layout.
	for _, c in ipairs(frame:GetChildren()) do
		if c:IsA("UIListLayout") or c:IsA("UIGridLayout") or c:IsA("UITableLayout") then
			warn(("[UiTheme] rivetRow skipped on %q: it uses a %s and rivets would become layout items")
				:format(frame.Name, c.ClassName))
			return
		end
	end
	inset = inset or 9
	spacing = spacing or 34
	local width = frame.AbsoluteSize.X
	-- AbsoluteSize is 0 until the frame has been laid out once, so fall back to the offset
	-- component, which is how every panel in this game is sized.
	if width <= 0 then
		width = frame.Size.X.Offset
	end
	local n = math.max(2, math.floor((width - inset * 2) / spacing))
	for i = 0, n do
		local x = inset + (width - inset * 2) * (i / n)
		UiTheme.rivet(frame, Vector2.new(0.5, 0.5), UDim2.new(0, x, 0, inset))
		UiTheme.rivet(frame, Vector2.new(0.5, 0.5), UDim2.new(0, x, 1, -inset))
	end
end

-- The brass sheen that keeps a flat colour from reading as flat.
local function sheen(inst, strength)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(
		Color3.new(1, 1, 1),
		Color3.new(1 - (strength or 0.25), 1 - (strength or 0.25), 1 - (strength or 0.25)))
	g.Parent = inst
	return g
end
UiTheme.sheen = sheen

----------------------------------------------------------------
-- Panel
----------------------------------------------------------------
-- opts: {parent, size, position, anchor, title, tone, padding, zindex}
-- returns {frame, body, header, titleLabel, accent, setTitle, setTone}
function UiTheme.panel(opts)
	local frame = Instance.new("Frame")
	frame.Name = opts.name or "Panel"
	frame.Size = opts.size or UDim2.fromOffset(400, 120)
	frame.Position = opts.position or UDim2.fromOffset(0, 0)
	frame.AnchorPoint = opts.anchor or Vector2.zero
	frame.BackgroundColor3 = UiTheme.C.iron
	frame.BackgroundTransparency = opts.transparency or 0.06
	frame.BorderSizePixel = 0
	frame.ZIndex = opts.zindex or 2
	frame.Parent = opts.parent
	corner(frame, 5)
	sheen(frame, 0.3)
	local edge = stroke(frame, UiTheme.C.brass, 2)

	-- Accent bar: the panel's tone, read at a glance before any word is.
	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.Size = UDim2.new(1, -16, 0, 3)
	accent.Position = UDim2.new(0, 8, 0, 4)
	accent.BackgroundColor3 = UiTheme.tone(opts.tone)
	accent.BorderSizePixel = 0
	accent.ZIndex = frame.ZIndex + 1
	accent.Parent = frame
	corner(accent, 2)

	local titleLabel
	if opts.title ~= nil then
		titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "Title"
		titleLabel.Size = UDim2.new(1, -24, 0, 16)
		titleLabel.Position = UDim2.new(0, 12, 0, 10)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Font = UiTheme.F.title
		titleLabel.TextSize = 14
		titleLabel.TextColor3 = UiTheme.C.brass
		titleLabel.TextXAlignment = Enum.TextXAlignment.Center
		titleLabel.Text = opts.title
		titleLabel.ZIndex = frame.ZIndex + 1
		titleLabel.Parent = frame
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ZIndex = frame.ZIndex + 1
	-- inset past the rivet line so content never collides with the frame detail
	local top = (opts.title ~= nil) and 30 or 14
	body.Position = UDim2.new(0, 16, 0, top)
	body.Size = UDim2.new(1, -32, 1, -(top + 12))
	body.Parent = frame

	UiTheme.rivetRow(frame)

	local api = {
		frame = frame, body = body, accent = accent,
		titleLabel = titleLabel, edge = edge,
	}
	function api.setTitle(text)
		if titleLabel then
			titleLabel.Text = text or ""
		end
	end
	function api.setTone(name)
		accent.BackgroundColor3 = UiTheme.tone(name)
	end
	return api
end

----------------------------------------------------------------
-- Text
----------------------------------------------------------------
-- opts: {text, style, tone, size, position, colour, wrap, zindex, scaled}
function UiTheme.text(parent, opts)
	-- An unknown style name used to take the whole client script down with "attempt to index
	-- nil with number", three frames into a playtest, pointing at this file rather than at the
	-- caller that misspelled it. A HUD is not worth losing a script over: warn, name the
	-- offender, and fall back to body text.
	local spec = STYLE[opts.style or "step"]
	if not spec then
		warn(("[UiTheme] unknown text style %q (falling back to \"step\")"):format(tostring(opts.style)))
		spec = STYLE.step
	end
	local l = Instance.new("TextLabel")
	l.Name = opts.name or "Text"
	l.BackgroundTransparency = 1
	l.Font = opts.font or spec[1]
	l.TextSize = opts.textSize or spec[2]
	l.TextColor3 = opts.colour or (opts.tone and UiTheme.tone(opts.tone)) or spec[3]
	l.TextXAlignment = opts.align or spec[4]
	l.TextYAlignment = opts.yAlign or Enum.TextYAlignment.Center
	l.Text = opts.text or ""
	l.TextWrapped = opts.wrap or false
	l.TextScaled = opts.scaled or false
	l.RichText = opts.rich or false
	l.Size = opts.size or UDim2.new(1, 0, 0, spec[2] + 6)
	l.Position = opts.position or UDim2.fromOffset(0, 0)
	l.AnchorPoint = opts.anchor or Vector2.zero
	l.ZIndex = opts.zindex or (parent.ZIndex or 1) + 1
	l.Parent = parent
	return l
end

-- A thin brass rule, for separating sections inside a panel.
function UiTheme.rule(parent, y, inset)
	local r = Instance.new("Frame")
	r.Name = "Rule"
	r.Size = UDim2.new(1, -(inset or 0) * 2, 0, 1)
	r.Position = UDim2.new(0, inset or 0, 0, y)
	r.BackgroundColor3 = UiTheme.C.brassDim
	r.BackgroundTransparency = 0.35
	r.BorderSizePixel = 0
	r.ZIndex = (parent.ZIndex or 1) + 1
	r.Parent = parent
	return r
end

----------------------------------------------------------------
-- A crate, drawn in 2D
----------------------------------------------------------------
-- The operator's job is "put one cube here" or "stack two cubes here", and a number is a
-- worse way to say that than a picture of one cube or two. Used by the overseer card.
function UiTheme.crateIcon(parent, opts)
	local holder = Instance.new("Frame")
	holder.Name = "CrateIcon"
	holder.BackgroundTransparency = 1
	holder.Size = opts.size or UDim2.fromOffset(34, 44)
	holder.Position = opts.position or UDim2.fromOffset(0, 0)
	holder.AnchorPoint = opts.anchor or Vector2.zero
	holder.ZIndex = opts.zindex or (parent.ZIndex or 1) + 1
	holder.Parent = parent

	local count = math.max(1, opts.count or 1)
	local cube = math.max(14, math.floor(holder.Size.Y.Offset / (count + 0.6)))
	for i = 1, count do
		local c = Instance.new("Frame")
		c.Name = "Cube" .. i
		c.AnchorPoint = Vector2.new(0.5, 1)
		c.Position = UDim2.new(0.5, 0, 1, -(i - 1) * (cube + 2))
		c.Size = UDim2.fromOffset(cube, cube)
		c.BackgroundColor3 = opts.colour or UiTheme.C.copper
		c.BorderSizePixel = 0
		c.ZIndex = holder.ZIndex + 1
		c.Parent = holder
		corner(c, 3)
		stroke(c, UiTheme.C.brass, 1.5)
		sheen(c, 0.35)
	end
	return holder
end

----------------------------------------------------------------
-- A diegetic brass plate: UI that lives on a part in the world, not on the screen.
----------------------------------------------------------------
-- The alternative is a BillboardGui, which always faces you, always draws on top, and never
-- belongs to the room. A plate bolted to the thing it describes reads as part of the machine
-- -- and crucially it occludes properly, so a label inside a sealed bay stays inside it.
function UiTheme.plate(part, opts)
	local existing = part:FindFirstChild("UiPlate")
	if existing then
		existing:Destroy()
	end
	local sg = Instance.new("SurfaceGui")
	sg.Name = "UiPlate"
	sg.Face = opts.face or Enum.NormalId.Front
	sg.LightInfluence = opts.lightInfluence or 0
	sg.PixelsPerStud = opts.ppu or 48
	sg.MaxDistance = opts.maxDistance or 90
	sg.Parent = part

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = UiTheme.C.ironDark
	bg.BackgroundTransparency = opts.transparency or 0.1
	bg.BorderSizePixel = 0
	bg.Parent = sg
	corner(bg, 4)
	stroke(bg, UiTheme.C.brass, 2)
	sheen(bg, 0.25)

	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.new(1, -10, 1, -8)
	l.BackgroundTransparency = 1
	l.Font = opts.font or UiTheme.F.title
	l.TextScaled = true
	l.TextColor3 = opts.colour or UiTheme.C.amber
	l.Text = opts.text or ""
	l.TextWrapped = true
	l.Parent = bg

	return {gui = sg, background = bg, label = l}
end

return UiTheme
