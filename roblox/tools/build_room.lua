-- Edit-time build script for Workspace.Room: the teen gamer bedroom around the Pattern Match table.
-- Visual only: walls, ceiling, wood floor, a big rug under the table, one window on the -X wall
-- (Glass pane, CastShadow off so sunlight gets in), gamer props along the walls (desk with three
-- monitors, chair and PC, bed with nightstand lamp, wall shelves, posters, a neon sign, beanbag, floor
-- lamp, plants, bookcase, dresser with TV and console, door), purple LED strips along the ceiling
-- edge, a blue LED desk glow, a ceiling light, and the player SpawnLocation (a small mat at
-- (0, 1, -3) facing -Z toward the table).
-- Also removes Workspace.Baseplate, the old Workspace.SpawnLocation and Workspace.PatternCabinet.Island.
-- Not part of the game: run it in Studio's command bar (or via the MCP execute_luau tool):
--   loadstring(game:GetService("HttpService"):GetAsync("http://127.0.0.1:8765/tools/build_room.lua"), "build_room")()
-- Re-runnable: deletes an existing Workspace.Room first (a Room.Props_Inserted folder, for Creator
-- Store models placed by hand, is kept). No Creator Store assets are used by this script.
-- Undo with Ctrl+Z.
--
-- Layout (studs). Interior X -48..48, Z -70..12, floor top Y = 1, ceiling underside Y = 27.
-- Kept clear for the boards: X -32..32, Z -52..-6, and the walkway X -6..6, Z -6..2.
-- Window: -X wall (X = -48), Z -40..-20, Y 6..20.

local ChangeHistoryService = game:GetService("ChangeHistoryService")

local FLOOR_Y = 1
local CEIL_Y = 27
local X0, X1 = -48, 48
local Z0, Z1 = -70, 12
local CX, CZ = (X0 + X1) / 2, (Z0 + Z1) / 2
local W, D = X1 - X0, Z1 - Z0
local WALL_T = 1
local WALL_H = CEIL_Y - FLOOR_Y
local WIN_Z0, WIN_Z1, WIN_Y0, WIN_Y1 = -40, -20, 6, 20

local C = {
	floor = Color3.fromRGB(138, 96, 62),
	ceiling = Color3.fromRGB(214, 214, 222),
	wall = Color3.fromRGB(56, 60, 94),
	accent = Color3.fromRGB(64, 44, 96),
	trim = Color3.fromRGB(34, 30, 46),
	white = Color3.fromRGB(236, 236, 240),
	black = Color3.fromRGB(24, 24, 30),
	charcoal = Color3.fromRGB(46, 46, 56),
	purple = Color3.fromRGB(150, 70, 255),
	blue = Color3.fromRGB(0, 170, 255),
	pink = Color3.fromRGB(255, 60, 180),
	cyan = Color3.fromRGB(40, 230, 220),
	warm = Color3.fromRGB(255, 226, 180),
	wood = Color3.fromRGB(110, 76, 50),
	darkWood = Color3.fromRGB(70, 48, 34),
	curtain = Color3.fromRGB(92, 58, 140),
	leaf = Color3.fromRGB(58, 140, 70),
	leafDark = Color3.fromRGB(40, 110, 56),
	pot = Color3.fromRGB(200, 110, 80),
	soil = Color3.fromRGB(60, 42, 30),
}

local function part(parent, name, size, cframe, color, material, opts)
	opts = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	if opts.shape then
		p.Shape = opts.shape
	end
	p.Size = size
	p.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = opts.collide ~= false
	p.CanQuery = opts.query ~= false
	p.CanTouch = false
	p.CastShadow = opts.shadow ~= false
	p.Transparency = opts.transparency or 0
	p.Parent = parent
	return p
end

-- Decorative bit: no collision, no query, no touch.
local function deco(parent, name, size, cframe, color, material, opts)
	opts = opts or {}
	opts.collide = false
	opts.query = false
	return part(parent, name, size, cframe, color, material, opts)
end

local function neon(parent, name, size, cframe, color)
	return deco(parent, name, size, cframe, color, Enum.Material.Neon, { shadow = false })
end

-- Vertical cylinder (Roblox cylinders run along local X).
local function vcyl(parent, name, height, diameter, center, color, material, opts)
	opts = opts or {}
	opts.shape = Enum.PartType.Cylinder
	return (opts.decor and deco or part)(parent, name, Vector3.new(height, diameter, diameter),
		CFrame.new(center) * CFrame.Angles(0, 0, math.rad(90)), color, material, opts)
end

local function ellipsoid(parent, name, size, cframe, color, material, opts)
	local p = (opts and opts.decor and deco or part)(parent, name, size, cframe, color, material, opts)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	return p
end

local function pointLight(parent, color, brightness, range, shadows)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Shadows = shadows or false
	l.Parent = parent
	return l
end

local function surfaceLight(parent, face, color, brightness, range, angle)
	local l = Instance.new("SurfaceLight")
	l.Face = face
	l.Color = color
	l.Brightness = brightness
	l.Range = range
	l.Angle = angle or 90
	l.Parent = parent
	return l
end

-- A SurfaceGui on the Front face of `p`; emissive = true ignores scene lighting (screens, signs).
local function gui(p, emissive)
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Front
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 40
	g.LightInfluence = emissive and 0 or 1
	if emissive then
		g.Brightness = 1.4
	end
	g.Parent = p
	return g
end

local function frame(parent, pos, size, color, props)
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = color
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	f.Parent = parent
	return f
end

local function text(parent, str, pos, size, color, font)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Text = str
	t.TextScaled = true
	t.Font = font or Enum.Font.GothamBlack
	t.TextColor3 = color
	t.Position = pos
	t.Size = size
	t.Parent = parent
	return t
end

local function gradient(parent, a, b, rotation)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(a, b)
	g.Rotation = rotation or 90
	g.Parent = parent
	parent.BackgroundColor3 = Color3.new(1, 1, 1) -- UIGradient multiplies the background color
	return g
end

-- Pixel art from rows of "X"/"." into a frame region.
local function pixels(parent, rows, color, pos, size)
	local holder = frame(parent, pos, size, Color3.new(), { BackgroundTransparency = 1 })
	local h, w = #rows, #rows[1]
	for r, row in ipairs(rows) do
		for c = 1, w do
			if row:sub(c, c) == "X" then
				frame(holder, UDim2.fromScale((c - 1) / w, (r - 1) / h), UDim2.fromScale(1 / w + 0.002, 1 / h + 0.002), color)
			end
		end
	end
	return holder
end

-- Framed poster on a wall: `center` on the wall face, `normal` pointing into the room.
-- Returns the canvas's SurfaceGui root frame.
local function poster(parent, name, center, normal, w, h, frameColor, emissive)
	local cf = CFrame.lookAt(center, center + normal)
	deco(parent, name .. "Frame", Vector3.new(w + 0.4, h + 0.4, 0.12), cf * CFrame.new(0, 0, -0.06), frameColor or C.black)
	local canvas = deco(parent, name, Vector3.new(w, h, 0.05), cf * CFrame.new(0, 0, -0.145), C.white)
	local root = frame(gui(canvas, emissive), UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), C.black)
	return root
end

local INVADER = {
	"..X.....X..",
	"...X...X...",
	"..XXXXXXX..",
	".XX.XXX.XX.",
	"XXXXXXXXXXX",
	"X.XXXXXXX.X",
	"X.X.....X.X",
	"...XX.XX...",
}
local HEART = {
	".XX.XX.",
	"XXXXXXX",
	"XXXXXXX",
	".XXXXX.",
	"..XXX..",
	"...X...",
}
local GHOST = {
	"..XXXX..",
	".XXXXXX.",
	"XX..X..X",
	"XX..X..X",
	"XXXXXXXX",
	"XXXXXXXX",
	"XXXXXXXX",
	"X.XX.XX.",
}

---------------------------------------------------------------------------------------------------

local recording = ChangeHistoryService:TryBeginRecording("Build Room")

local kept
local old = workspace:FindFirstChild("Room")
if old then
	kept = old:FindFirstChild("Props_Inserted")
	if kept then
		kept.Parent = nil
	end
	old:Destroy()
end
for _, name in ipairs({ "Baseplate", "SpawnLocation" }) do
	local x = workspace:FindFirstChild(name)
	if x then
		x:Destroy()
	end
end
local cabinet = workspace:FindFirstChild("PatternCabinet")
if cabinet and cabinet:FindFirstChild("Island") then
	cabinet.Island:Destroy()
end

local room = Instance.new("Folder")
room.Name = "Room"
room.Parent = workspace
if kept then
	kept.Parent = room
end

local function group(name)
	local f = Instance.new("Folder")
	f.Name = name
	return f
end

local function flush(f)
	f.Parent = room
	task.wait()
end

-- Shell: floor, ceiling, walls (with the window hole), baseboards, rug ---------------------------
do
	local g = group("Shell")
	part(g, "Floor", Vector3.new(W + 2, 1, D + 2), Vector3.new(CX, FLOOR_Y - 0.5, CZ), C.floor, Enum.Material.WoodPlanks)
	part(g, "Ceiling", Vector3.new(W + 2, 1, D + 2), Vector3.new(CX, CEIL_Y + 0.5, CZ), C.ceiling)
	local wy = FLOOR_Y + WALL_H / 2
	part(g, "WallBack", Vector3.new(W + 2, WALL_H, WALL_T), Vector3.new(CX, wy, Z0 - 0.5), C.accent)
	part(g, "WallFront", Vector3.new(W + 2, WALL_H, WALL_T), Vector3.new(CX, wy, Z1 + 0.5), C.wall)
	part(g, "WallRight", Vector3.new(WALL_T, WALL_H, D), Vector3.new(X1 + 0.5, wy, CZ), C.wall)
	-- -X wall in four pieces around the window opening
	local wx = X0 - 0.5
	part(g, "WallLeftLow", Vector3.new(WALL_T, WIN_Y0 - FLOOR_Y, D), Vector3.new(wx, (FLOOR_Y + WIN_Y0) / 2, CZ), C.wall)
	part(g, "WallLeftHigh", Vector3.new(WALL_T, CEIL_Y - WIN_Y1, D), Vector3.new(wx, (WIN_Y1 + CEIL_Y) / 2, CZ), C.wall)
	part(g, "WallLeftBack", Vector3.new(WALL_T, WIN_Y1 - WIN_Y0, WIN_Z0 - Z0), Vector3.new(wx, (WIN_Y0 + WIN_Y1) / 2, (Z0 + WIN_Z0) / 2), C.wall)
	part(g, "WallLeftFront", Vector3.new(WALL_T, WIN_Y1 - WIN_Y0, Z1 - WIN_Z1), Vector3.new(wx, (WIN_Y0 + WIN_Y1) / 2, (WIN_Z1 + Z1) / 2), C.wall)
	-- baseboards
	local bb = 0.7
	deco(g, "BaseboardBack", Vector3.new(W, bb, 0.3), Vector3.new(CX, FLOOR_Y + bb / 2, Z0 + 0.15), C.trim)
	deco(g, "BaseboardFront", Vector3.new(W, bb, 0.3), Vector3.new(CX, FLOOR_Y + bb / 2, Z1 - 0.15), C.trim)
	deco(g, "BaseboardRight", Vector3.new(0.3, bb, D), Vector3.new(X1 - 0.15, FLOOR_Y + bb / 2, CZ), C.trim)
	deco(g, "BaseboardLeft", Vector3.new(0.3, bb, D), Vector3.new(X0 + 0.15, FLOOR_Y + bb / 2, CZ), C.trim)
	-- crown trim the LED strips sit under
	deco(g, "CrownBack", Vector3.new(W, 0.5, 0.6), Vector3.new(CX, CEIL_Y - 0.25, Z0 + 0.3), C.trim)
	deco(g, "CrownFront", Vector3.new(W, 0.5, 0.6), Vector3.new(CX, CEIL_Y - 0.25, Z1 - 0.3), C.trim)
	deco(g, "CrownRight", Vector3.new(0.6, 0.5, D), Vector3.new(X1 - 0.3, CEIL_Y - 0.25, CZ), C.trim)
	deco(g, "CrownLeft", Vector3.new(0.6, 0.5, D), Vector3.new(X0 + 0.3, CEIL_Y - 0.25, CZ), C.trim)
	-- big rug under the table (thin, no collision so players walk on the floor under it)
	deco(g, "RugBorder", Vector3.new(56, 0.06, 40), Vector3.new(0, FLOOR_Y + 0.03, -29.5), Color3.fromRGB(52, 40, 78), Enum.Material.Fabric)
	deco(g, "Rug", Vector3.new(52, 0.08, 36), Vector3.new(0, FLOOR_Y + 0.04, -29.5), Color3.fromRGB(78, 88, 122), Enum.Material.Fabric)
	flush(g)
end

-- Window on the -X wall ---------------------------------------------------------------------------
do
	local g = group("Window")
	local wx = X0 - 0.5
	local zc, yc = (WIN_Z0 + WIN_Z1) / 2, (WIN_Y0 + WIN_Y1) / 2
	local ww, wh = WIN_Z1 - WIN_Z0, WIN_Y1 - WIN_Y0
	part(g, "Glass", Vector3.new(0.2, wh, ww), Vector3.new(wx, yc, zc), Color3.fromRGB(205, 228, 255), Enum.Material.Glass,
		{ transparency = 0.75, shadow = false, collide = true, query = false })
	-- frame trim (casts the window-pane shadow pattern into the room)
	local t = 0.6
	deco(g, "FrameTop", Vector3.new(1.6, t, ww + 2 * t), Vector3.new(wx + 0.3, WIN_Y1 + t / 2, zc), C.white)
	deco(g, "FrameLeft", Vector3.new(1.6, wh, t), Vector3.new(wx + 0.3, yc, WIN_Z0 - t / 2), C.white)
	deco(g, "FrameRight", Vector3.new(1.6, wh, t), Vector3.new(wx + 0.3, yc, WIN_Z1 + t / 2), C.white)
	deco(g, "Sill", Vector3.new(2.2, 0.4, ww + 2 * t + 0.6), Vector3.new(wx + 0.6, WIN_Y0 - 0.2, zc), C.white)
	deco(g, "MullionV", Vector3.new(0.5, wh, 0.3), Vector3.new(wx, yc, zc), C.white)
	deco(g, "MullionH", Vector3.new(0.5, 0.3, ww), Vector3.new(wx, yc, zc), C.white)
	-- curtains and rod
	local cx = X0 + 0.8
	deco(g, "CurtainRod", Vector3.new(30, 0.25, 0.25), CFrame.new(cx, WIN_Y1 + 1.4, zc) * CFrame.Angles(0, math.rad(90), 0), C.black, Enum.Material.Metal,
		{ shape = Enum.PartType.Cylinder })
	deco(g, "CurtainA", Vector3.new(0.5, wh + 3, 4.5), Vector3.new(cx, yc + 0.2, WIN_Z0 - 1.6), C.curtain, Enum.Material.Fabric)
	deco(g, "CurtainB", Vector3.new(0.5, wh + 3, 4.5), Vector3.new(cx, yc + 0.2, WIN_Z1 + 1.6), C.curtain, Enum.Material.Fabric)
	flush(g)
end

-- Lights: ceiling LED strips, ceiling fixture ----------------------------------------------------
do
	local g = group("Lights")
	local y = CEIL_Y - 0.65
	local strips = {
		{ "LEDBack", Vector3.new(W - 1.4, 0.3, 0.3), Vector3.new(CX, y, Z0 + 0.45) },
		{ "LEDFront", Vector3.new(W - 1.4, 0.3, 0.3), Vector3.new(CX, y, Z1 - 0.45) },
		{ "LEDRight", Vector3.new(0.3, 0.3, D - 1.4), Vector3.new(X1 - 0.45, y, CZ) },
		{ "LEDLeft", Vector3.new(0.3, 0.3, D - 1.4), Vector3.new(X0 + 0.45, y, CZ) },
	}
	for _, s in ipairs(strips) do
		local p = neon(g, s[1], s[2], s[3], C.purple)
		surfaceLight(p, Enum.NormalId.Bottom, C.purple, 1, 14, 100)
	end
	-- round ceiling fixture over the table
	local fx, fz = 0, -29.5
	vcyl(g, "CeilingLampBase", 0.5, 7.5, Vector3.new(fx, CEIL_Y - 0.25, fz), C.white, Enum.Material.SmoothPlastic, { decor = true })
	local bulb = vcyl(g, "CeilingLamp", 0.3, 6.4, Vector3.new(fx, CEIL_Y - 0.6, fz), Color3.fromRGB(255, 244, 228), Enum.Material.Neon,
		{ decor = true, shadow = false })
	pointLight(bulb, Color3.fromRGB(255, 236, 210), 1.2, 45, true)
	flush(g)
end

-- Gaming desk on the back wall --------------------------------------------------------------------
do
	local g = group("GamingDesk")
	local dx, dz = 14, Z0 + 2.6 -- desk center
	local topY = FLOOR_Y + 2.8
	part(g, "DeskTop", Vector3.new(16, 0.4, 5), Vector3.new(dx, topY - 0.2, dz), C.black)
	part(g, "DeskLegL", Vector3.new(0.5, topY - 0.4 - FLOOR_Y, 4.6), Vector3.new(dx - 7.5, (FLOOR_Y + topY - 0.4) / 2, dz), C.charcoal, Enum.Material.Metal)
	part(g, "DeskLegR", Vector3.new(0.5, topY - 0.4 - FLOOR_Y, 4.6), Vector3.new(dx + 7.5, (FLOOR_Y + topY - 0.4) / 2, dz), C.charcoal, Enum.Material.Metal)
	deco(g, "DeskModesty", Vector3.new(15, 1.4, 0.2), Vector3.new(dx, topY - 1.1, dz - 2.2), C.charcoal, Enum.Material.Metal)
	local edge = neon(g, "DeskLED", Vector3.new(15.6, 0.1, 0.12), Vector3.new(dx, topY - 0.45, dz + 2.42), C.blue)
	surfaceLight(edge, Enum.NormalId.Bottom, C.blue, 1.5, 8, 110)
	local wallGlow = neon(g, "WallLED", Vector3.new(16, 0.15, 0.1), Vector3.new(dx, topY + 0.1, Z0 + 0.1), C.blue)
	surfaceLight(wallGlow, Enum.NormalId.Top, C.blue, 2, 10, 70)

	-- three monitors, each facing a viewer sitting in the chair
	local viewer = Vector3.new(dx, topY + 3, dz + 7)
	local function monitor(name, pos, w, h, paint)
		local cf = CFrame.lookAt(pos, pos - (viewer - pos)) -- local +Z points at the viewer
		part(g, name, Vector3.new(w + 0.3, h + 0.3, 0.25), cf, C.black)
		local screen = deco(g, name .. "Screen", Vector3.new(w, h, 0.05), cf * CFrame.new(0, 0, 0.14) * CFrame.Angles(0, math.pi, 0), C.black)
		paint(frame(gui(screen, true), UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), C.black))
		local bottomY = pos.Y - h / 2
		deco(g, name .. "Neck", Vector3.new(0.35, bottomY - topY + 0.3, 0.3),
			CFrame.new(pos.X, (topY + bottomY) / 2 + 0.15, pos.Z) * cf.Rotation * CFrame.new(0, 0, -0.3), C.charcoal, Enum.Material.Metal)
		deco(g, name .. "Foot", Vector3.new(1.6, 0.12, 1.1), CFrame.new(pos.X, topY + 0.06, pos.Z) * cf.Rotation * CFrame.new(0, 0, -0.3), C.charcoal, Enum.Material.Metal)
	end
	local screenY = topY + 2.9
	monitor("MonitorCenter", Vector3.new(dx, screenY, dz - 1.1), 5.2, 3, function(root)
		gradient(root, Color3.fromRGB(20, 30, 70), Color3.fromRGB(70, 20, 90), 90)
		text(root, "PATTERN MATCH", UDim2.fromScale(0.1, 0.06), UDim2.fromScale(0.8, 0.18), C.white)
		local cols = { C.pink, C.cyan, Color3.fromRGB(255, 210, 60), C.purple }
		for r = 0, 3 do
			for c = 0, 5 do
				frame(root, UDim2.fromScale(0.2 + c * 0.1, 0.32 + r * 0.15), UDim2.fromScale(0.085, 0.12), cols[(r * 6 + c) % 4 + 1])
			end
		end
	end)
	monitor("MonitorLeft", Vector3.new(dx - 5.1, screenY, dz - 0.4), 4.4, 2.6, function(root)
		gradient(root, Color3.fromRGB(10, 14, 30), Color3.fromRGB(30, 40, 80), 90)
		for i = 0, 6 do
			frame(root, UDim2.fromScale(0.06, 0.08 + i * 0.12), UDim2.fromScale(0.3 + (i * 37 % 50) / 100, 0.06), i % 2 == 0 and C.cyan or C.purple)
		end
	end)
	monitor("MonitorRight", Vector3.new(dx + 5.1, screenY, dz - 0.4), 4.4, 2.6, function(root)
		gradient(root, Color3.fromRGB(40, 10, 50), Color3.fromRGB(10, 10, 30), 90)
		pixels(root, GHOST, C.pink, UDim2.fromScale(0.3, 0.15), UDim2.fromScale(0.4, 0.7))
	end)
	-- keyboard, mouse, pad, cans, desk plant
	deco(g, "MousePad", Vector3.new(7, 0.05, 2.4), Vector3.new(dx, topY + 0.025, dz + 1.1), C.black, Enum.Material.Fabric)
	neon(g, "MousePadGlow", Vector3.new(7.1, 0.03, 2.5), Vector3.new(dx, topY + 0.015, dz + 1.1), C.purple)
	deco(g, "Keyboard", Vector3.new(3.6, 0.18, 1.1), Vector3.new(dx - 0.8, topY + 0.14, dz + 1.1), C.charcoal)
	neon(g, "KeyboardGlow", Vector3.new(3.4, 0.03, 0.9), Vector3.new(dx - 0.8, topY + 0.245, dz + 1.1), C.cyan)
	deco(g, "Mouse", Vector3.new(0.4, 0.2, 0.65), Vector3.new(dx + 2.2, topY + 0.15, dz + 1.2), C.charcoal)
	vcyl(g, "Can1", 0.65, 0.36, Vector3.new(dx + 6.6, topY + 0.33, dz + 1.3), Color3.fromRGB(60, 220, 90), Enum.Material.Metal, { decor = true })
	vcyl(g, "Can2", 0.65, 0.36, Vector3.new(dx + 6.1, topY + 0.33, dz + 1.7), Color3.fromRGB(60, 220, 90), Enum.Material.Metal, { decor = true })
	-- headset stand
	vcyl(g, "HeadsetStand", 1.6, 0.15, Vector3.new(dx - 6.6, topY + 0.8, dz + 0.8), C.charcoal, Enum.Material.Metal, { decor = true })
	deco(g, "Headset", Vector3.new(0.4, 1.0, 1.2), Vector3.new(dx - 6.6, topY + 1.5, dz + 0.8), C.black)
	neon(g, "HeadsetGlowA", Vector3.new(0.45, 0.5, 0.08), Vector3.new(dx - 6.6, topY + 1.25, dz + 0.22), C.pink)
	neon(g, "HeadsetGlowB", Vector3.new(0.45, 0.5, 0.08), Vector3.new(dx - 6.6, topY + 1.25, dz + 1.38), C.pink)

	-- PC tower on the floor right of the desk
	local tx = dx + 9.7
	local towerH = 4.6
	part(g, "PCTower", Vector3.new(2.2, towerH, 4.4), Vector3.new(tx, FLOOR_Y + towerH / 2, dz), C.black)
	local panel = deco(g, "PCGlass", Vector3.new(0.05, towerH - 0.6, 3.8), Vector3.new(tx - 1.12, FLOOR_Y + towerH / 2, dz), Color3.fromRGB(30, 20, 50), Enum.Material.Glass,
		{ transparency = 0.2 })
	pointLight(panel, C.pink, 1, 7)
	for i = 0, 2 do
		deco(g, "PCFan" .. (i + 1), Vector3.new(0.06, 1.1, 1.1), CFrame.new(tx, FLOOR_Y + 1.1 + i * 1.3, dz + 2.22) * CFrame.Angles(0, math.rad(90), 0),
			C.cyan, Enum.Material.Neon, { shape = Enum.PartType.Cylinder, shadow = false })
	end
	neon(g, "PCStripe", Vector3.new(0.06, towerH - 0.6, 0.1), Vector3.new(tx - 1.15, FLOOR_Y + towerH / 2, dz + 1.95), C.pink)

	-- gaming chair, facing the desk (-Z)
	local chz = dz + 5.5
	vcyl(g, "ChairBase", 0.25, 3, Vector3.new(dx, FLOOR_Y + 0.35, chz), C.black, Enum.Material.Metal, { decor = true })
	for i = 0, 4 do
		local a = i * math.pi * 2 / 5
		deco(g, "ChairCaster" .. (i + 1), Vector3.new(0.35, 0.35, 0.35), Vector3.new(dx + math.cos(a) * 1.4, FLOOR_Y + 0.17, chz + math.sin(a) * 1.4), C.black,
			Enum.Material.SmoothPlastic, { shape = Enum.PartType.Ball })
	end
	vcyl(g, "ChairPost", 1.6, 0.4, Vector3.new(dx, FLOOR_Y + 1.25, chz), C.charcoal, Enum.Material.Metal, { decor = true })
	local seatY = FLOOR_Y + 2.2
	part(g, "ChairSeat", Vector3.new(3.2, 0.6, 3.2), Vector3.new(dx, seatY, chz), C.black, Enum.Material.Fabric)
	local back = CFrame.new(dx, seatY + 2.6, chz + 1.55) * CFrame.Angles(math.rad(-8), 0, 0)
	part(g, "ChairBack", Vector3.new(3.2, 4.6, 0.5), back, C.black, Enum.Material.Fabric)
	deco(g, "ChairStripeL", Vector3.new(0.5, 4.4, 0.06), back * CFrame.new(-0.9, 0, -0.27), C.purple, Enum.Material.Fabric)
	deco(g, "ChairStripeR", Vector3.new(0.5, 4.4, 0.06), back * CFrame.new(0.9, 0, -0.27), C.purple, Enum.Material.Fabric)
	deco(g, "ChairPillow", Vector3.new(1.6, 0.7, 0.4), back * CFrame.new(0, 1.6, -0.4), C.purple, Enum.Material.Fabric)
	deco(g, "ChairArmL", Vector3.new(0.4, 0.25, 2.2), Vector3.new(dx - 1.75, seatY + 1.2, chz + 0.1), C.charcoal)
	deco(g, "ChairArmR", Vector3.new(0.4, 0.25, 2.2), Vector3.new(dx + 1.75, seatY + 1.2, chz + 0.1), C.charcoal)
	deco(g, "ChairArmPostL", Vector3.new(0.25, 1.0, 0.25), Vector3.new(dx - 1.75, seatY + 0.6, chz + 0.6), C.charcoal)
	deco(g, "ChairArmPostR", Vector3.new(0.25, 1.0, 0.25), Vector3.new(dx + 1.75, seatY + 0.6, chz + 0.6), C.charcoal)

	-- big poster above the desk
	local root = poster(g, "PosterLevelUp", Vector3.new(dx, 15, Z0), Vector3.new(0, 0, 1), 10, 6, C.black)
	gradient(root, Color3.fromRGB(30, 10, 60), Color3.fromRGB(10, 40, 90), 90)
	pixels(root, INVADER, C.cyan, UDim2.fromScale(0.3, 0.08), UDim2.fromScale(0.4, 0.55))
	text(root, "LEVEL UP", UDim2.fromScale(0.1, 0.7), UDim2.fromScale(0.8, 0.22), C.pink)
	flush(g)
end

-- Wall shelves + neon sign on the back wall, left of center ---------------------------------------
do
	local g = group("Shelves")
	local sx, sz = -16, Z0 + 1
	for i, y in ipairs({ 8, 12 }) do
		part(g, "Shelf" .. i, Vector3.new(12, 0.35, 2), Vector3.new(sx, y, sz), C.wood, Enum.Material.Wood, { query = false })
		deco(g, "ShelfBracket" .. i .. "A", Vector3.new(0.3, 0.8, 1.6), Vector3.new(sx - 5, y - 0.55, sz - 0.2), C.charcoal, Enum.Material.Metal)
		deco(g, "ShelfBracket" .. i .. "B", Vector3.new(0.3, 0.8, 1.6), Vector3.new(sx + 5, y - 0.55, sz - 0.2), C.charcoal, Enum.Material.Metal)
	end
	-- lower shelf: books + a trophy
	local bookColors = { C.pink, C.blue, Color3.fromRGB(255, 200, 60), C.leaf, C.purple, Color3.fromRGB(230, 90, 60) }
	local bx = sx - 5.2
	for i, col in ipairs(bookColors) do
		local h = 1.5 + (i % 3) * 0.25
		deco(g, "Book" .. i, Vector3.new(0.45, h, 1.4), Vector3.new(bx, 8.175 + h / 2, sz), col)
		bx += 0.5
	end
	deco(g, "BookLeaning", Vector3.new(0.45, 1.6, 1.4), CFrame.new(bx + 0.45, 8.175 + 0.78, sz) * CFrame.Angles(0, 0, math.rad(-20)), C.cyan)
	local gold = Color3.fromRGB(240, 190, 60)
	deco(g, "TrophyBase", Vector3.new(1, 0.4, 1), Vector3.new(sx + 3.5, 8.375, sz), C.black)
	vcyl(g, "TrophyStem", 0.7, 0.25, Vector3.new(sx + 3.5, 8.925, sz), gold, Enum.Material.Metal, { decor = true })
	vcyl(g, "TrophyCup", 0.8, 0.9, Vector3.new(sx + 3.5, 9.67, sz), gold, Enum.Material.Metal, { decor = true })
	-- upper shelf: a blocky robot figure, a puzzle cube, a little plant
	local ry = 12.175
	deco(g, "RobotLegs", Vector3.new(0.8, 0.6, 0.5), Vector3.new(sx - 3.5, ry + 0.3, sz), C.charcoal)
	deco(g, "RobotBody", Vector3.new(1.0, 0.9, 0.6), Vector3.new(sx - 3.5, ry + 1.05, sz), Color3.fromRGB(250, 160, 40))
	deco(g, "RobotHead", Vector3.new(0.7, 0.55, 0.55), Vector3.new(sx - 3.5, ry + 1.78, sz), C.white)
	neon(g, "RobotEyes", Vector3.new(0.45, 0.12, 0.05), Vector3.new(sx - 3.5, ry + 1.8, sz + 0.28), C.cyan)
	local cube = deco(g, "PuzzleCube", Vector3.new(0.9, 0.9, 0.9), CFrame.new(sx, ry + 0.45, sz) * CFrame.Angles(0, math.rad(25), 0), C.black)
	local cubeFaces = {
		[Enum.NormalId.Front] = C.pink,
		[Enum.NormalId.Right] = Color3.fromRGB(255, 200, 60),
		[Enum.NormalId.Top] = C.cyan,
	}
	for face, col in pairs(cubeFaces) do
		local sg = Instance.new("SurfaceGui")
		sg.Face = face
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 60
		sg.Parent = cube
		for r = 0, 2 do
			for c = 0, 2 do
				frame(sg, UDim2.fromScale(0.03 + c * 0.33, 0.03 + r * 0.33), UDim2.fromScale(0.28, 0.28), (r + c) % 2 == 0 and col or C.white)
			end
		end
	end
	vcyl(g, "ShelfPlantPot", 0.8, 0.9, Vector3.new(sx + 3.5, ry + 0.4, sz), C.pot, Enum.Material.SmoothPlastic, { decor = true })
	ellipsoid(g, "ShelfPlantLeaves", Vector3.new(1.4, 1.1, 1.4), CFrame.new(sx + 3.5, ry + 1.25, sz), C.leaf, Enum.Material.Grass, { decor = true })

	-- neon sign above the shelves
	local signPos = Vector3.new(sx, 17, Z0 + 0.06)
	local sign = deco(g, "NeonSign", Vector3.new(10, 2.6, 0.05), CFrame.lookAt(signPos, signPos + Vector3.new(0, 0, 1)), C.black, Enum.Material.SmoothPlastic,
		{ transparency = 1, shadow = false })
	local sg = gui(sign, true)
	sg.Brightness = 2.5
	local t = text(sg, "PLAYER 1", UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), C.pink, Enum.Font.Arcade)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(255, 160, 230)
	stroke.Thickness = 2
	stroke.Parent = t
	pointLight(sign, C.pink, 0.8, 9)
	flush(g)
end

-- Bed + nightstand lamp on the +X wall -------------------------------------------------------------
do
	local g = group("Bed")
	local bz = -40
	local len, wid = 8.6, 6.8
	local bx = X1 - len / 2
	part(g, "BedFrame", Vector3.new(len, 1.2, wid), Vector3.new(bx, FLOOR_Y + 0.6, bz), C.charcoal)
	part(g, "Mattress", Vector3.new(len - 0.6, 1.0, wid - 0.4), Vector3.new(bx - 0.1, FLOOR_Y + 1.7, bz), C.white, Enum.Material.Fabric)
	deco(g, "Blanket", Vector3.new(5.6, 0.3, wid - 0.1), Vector3.new(bx - 1.4, FLOOR_Y + 2.3, bz), Color3.fromRGB(40, 150, 170), Enum.Material.Fabric)
	deco(g, "BlanketFold", Vector3.new(0.9, 0.35, wid - 0.1), Vector3.new(bx + 1.1, FLOOR_Y + 2.4, bz), Color3.fromRGB(230, 230, 236), Enum.Material.Fabric)
	deco(g, "PillowA", Vector3.new(1.3, 0.6, 2.7), Vector3.new(X1 - 1.3, FLOOR_Y + 2.5, bz - 1.6), C.white, Enum.Material.Fabric)
	deco(g, "PillowB", Vector3.new(1.3, 0.6, 2.7), Vector3.new(X1 - 1.3, FLOOR_Y + 2.5, bz + 1.6), C.purple, Enum.Material.Fabric)
	part(g, "Headboard", Vector3.new(0.6, 4.6, wid + 0.4), Vector3.new(X1 - 0.3, FLOOR_Y + 2.3, bz), C.charcoal, Enum.Material.Fabric)
	local hb = neon(g, "HeadboardLED", Vector3.new(0.12, 0.12, wid + 0.4), Vector3.new(X1 - 0.65, FLOOR_Y + 4.55, bz), C.blue)
	surfaceLight(hb, Enum.NormalId.Top, C.blue, 1, 8, 90)
	-- nightstand + lamp
	local nz = bz - wid / 2 - 1.8
	local nx = X1 - 1.5
	part(g, "Nightstand", Vector3.new(2.6, 2.4, 2.6), Vector3.new(nx, FLOOR_Y + 1.2, nz), C.wood, Enum.Material.Wood)
	deco(g, "NightstandDrawer", Vector3.new(0.06, 0.8, 2.0), Vector3.new(nx - 1.31, FLOOR_Y + 1.5, nz), C.darkWood, Enum.Material.Wood)
	vcyl(g, "LampBase", 0.2, 0.9, Vector3.new(nx, FLOOR_Y + 2.5, nz), C.black, Enum.Material.Metal, { decor = true })
	vcyl(g, "LampStem", 1.1, 0.15, Vector3.new(nx, FLOOR_Y + 3.15, nz), C.black, Enum.Material.Metal, { decor = true })
	local shade = vcyl(g, "LampShade", 1.0, 1.4, Vector3.new(nx, FLOOR_Y + 4.0, nz), C.warm, Enum.Material.Fabric, { decor = true, shadow = false })
	pointLight(shade, C.warm, 0.8, 10, true)
	-- wardrobe further along the wall, with a game-box stack on top
	local wz = -61
	part(g, "Wardrobe", Vector3.new(3.4, 11, 8), Vector3.new(X1 - 1.7, FLOOR_Y + 5.5, wz), C.white, Enum.Material.Wood)
	deco(g, "WardrobeSeam", Vector3.new(0.06, 10.6, 0.1), Vector3.new(X1 - 3.43, FLOOR_Y + 5.5, wz), C.charcoal)
	deco(g, "WardrobeHandleA", Vector3.new(0.15, 1.6, 0.2), Vector3.new(X1 - 3.5, FLOOR_Y + 5.5, wz - 0.4), C.charcoal, Enum.Material.Metal)
	deco(g, "WardrobeHandleB", Vector3.new(0.15, 1.6, 0.2), Vector3.new(X1 - 3.5, FLOOR_Y + 5.5, wz + 0.4), C.charcoal, Enum.Material.Metal)
	local boxColors = { C.pink, C.blue, Color3.fromRGB(255, 200, 60) }
	for i, col in ipairs(boxColors) do
		deco(g, "GameBox" .. i, Vector3.new(2.2, 0.8, 2.8), CFrame.new(X1 - 1.8, FLOOR_Y + 11 + 0.4 + (i - 1) * 0.8, wz + 1) * CFrame.Angles(0, math.rad(i * 9 - 9), 0), col)
	end
	-- posters above the bed
	local r1 = poster(g, "PosterHeart", Vector3.new(X1, 10.5, bz - 4.5), Vector3.new(-1, 0, 0), 4.5, 6, C.white)
	gradient(r1, Color3.fromRGB(255, 120, 160), Color3.fromRGB(120, 40, 140), 90)
	pixels(r1, HEART, C.white, UDim2.fromScale(0.15, 0.12), UDim2.fromScale(0.7, 0.45))
	text(r1, "1UP", UDim2.fromScale(0.15, 0.68), UDim2.fromScale(0.7, 0.2), C.white, Enum.Font.Arcade)
	local r2 = poster(g, "PosterGhost", Vector3.new(X1, 10.5, bz + 4.5), Vector3.new(-1, 0, 0), 4.5, 6, C.white)
	gradient(r2, Color3.fromRGB(10, 10, 40), Color3.fromRGB(40, 20, 90), 90)
	pixels(r2, GHOST, C.cyan, UDim2.fromScale(0.2, 0.12), UDim2.fromScale(0.6, 0.45))
	text(r2, "GAME OVER", UDim2.fromScale(0.08, 0.68), UDim2.fromScale(0.84, 0.18), C.pink, Enum.Font.Arcade)
	flush(g)
end

-- Lounge corner by the window: beanbag, floor lamp, big plant --------------------------------------
do
	local g = group("Lounge")
	local bx, bz = -40.5, -48
	ellipsoid(g, "Beanbag", Vector3.new(5.6, 3.0, 5.6), CFrame.new(bx, FLOOR_Y + 1.3, bz), Color3.fromRGB(230, 70, 90), Enum.Material.Fabric)
	ellipsoid(g, "BeanbagBack", Vector3.new(2.6, 3.6, 4.6), CFrame.new(bx - 2.1, FLOOR_Y + 2.1, bz - 0.6) * CFrame.Angles(0, math.rad(-20), math.rad(-12)),
		Color3.fromRGB(215, 60, 82), Enum.Material.Fabric, { decor = true })
	-- floor lamp
	local lx, lz = -45.5, -54
	vcyl(g, "FloorLampBase", 0.25, 2, Vector3.new(lx, FLOOR_Y + 0.125, lz), C.black, Enum.Material.Metal, { decor = true })
	part(g, "FloorLampPole", Vector3.new(0.25, 9, 0.25), Vector3.new(lx, FLOOR_Y + 4.6, lz), C.black, Enum.Material.Metal)
	local shade = vcyl(g, "FloorLampShade", 2.0, 2.6, Vector3.new(lx, FLOOR_Y + 10, lz), C.warm, Enum.Material.Fabric, { decor = true, shadow = false })
	pointLight(shade, C.warm, 1, 16, true)
	-- big corner plant
	local px, pz = -45, -66.5
	vcyl(g, "PlantPot", 2.4, 2.6, Vector3.new(px, FLOOR_Y + 1.2, pz), Color3.fromRGB(235, 235, 240), Enum.Material.SmoothPlastic)
	vcyl(g, "PlantSoil", 0.1, 2.3, Vector3.new(px, FLOOR_Y + 2.38, pz), C.soil, Enum.Material.Ground, { decor = true })
	deco(g, "PlantTrunk", Vector3.new(0.3, 3.5, 0.3), Vector3.new(px, FLOOR_Y + 4.1, pz), C.darkWood, Enum.Material.Wood)
	local leaves = {
		{ Vector3.new(0, 6.4, 0), 3.2 },
		{ Vector3.new(0.9, 5.4, 0.6), 2.4 },
		{ Vector3.new(-0.8, 5.6, -0.7), 2.4 },
		{ Vector3.new(0.2, 7.6, -0.3), 2.0 },
	}
	for i, l in ipairs(leaves) do
		ellipsoid(g, "PlantLeaves" .. i, Vector3.new(l[2], l[2] * 0.8, l[2]), CFrame.new(px + l[1].X, FLOOR_Y + l[1].Y, pz + l[1].Z),
			i % 2 == 0 and C.leafDark or C.leaf, Enum.Material.Grass, { decor = true })
	end
	-- poster near the plant
	local r = poster(g, "PosterRacer", Vector3.new(X0, 12, -60), Vector3.new(1, 0, 0), 5, 7, C.black)
	gradient(r, Color3.fromRGB(255, 140, 40), Color3.fromRGB(150, 30, 120), 90)
	text(r, "SPACE", UDim2.fromScale(0.1, 0.08), UDim2.fromScale(0.8, 0.16), C.white)
	text(r, "RACER", UDim2.fromScale(0.1, 0.24), UDim2.fromScale(0.8, 0.16), C.white)
	frame(r, UDim2.fromScale(0.3, 0.55), UDim2.fromScale(0.4, 0.06), C.white)
	frame(r, UDim2.fromScale(0.45, 0.45), UDim2.fromScale(0.1, 0.25), C.white)
	frame(r, UDim2.fromScale(0.0, 0.85), UDim2.fromScale(1, 0.04), C.cyan)
	flush(g)
end

-- Back wall right: a robot-arm blueprint poster + a wall clock -----------------------------------
do
	local g = group("BackWallDecor")
	local r = poster(g, "PosterBlueprint", Vector3.new(36, 13, Z0), Vector3.new(0, 0, 1), 8, 6, C.white)
	gradient(r, Color3.fromRGB(20, 70, 160), Color3.fromRGB(10, 40, 110), 90)
	local line = Color3.fromRGB(210, 230, 255)
	frame(r, UDim2.fromScale(0.15, 0.78), UDim2.fromScale(0.3, 0.05), line)        -- base
	frame(r, UDim2.fromScale(0.27, 0.42), UDim2.fromScale(0.04, 0.38), line)       -- upper arm
	frame(r, UDim2.fromScale(0.27, 0.40), UDim2.fromScale(0.36, 0.04), line)       -- forearm
	frame(r, UDim2.fromScale(0.6, 0.40), UDim2.fromScale(0.04, 0.18), line)        -- wrist
	frame(r, UDim2.fromScale(0.57, 0.58), UDim2.fromScale(0.1, 0.03), line)        -- gripper
	text(r, "SO-101", UDim2.fromScale(0.62, 0.72), UDim2.fromScale(0.32, 0.16), line, Enum.Font.Code)
	text(r, "ROBOT ARM // REV B", UDim2.fromScale(0.05, 0.05), UDim2.fromScale(0.6, 0.1), line, Enum.Font.Code)
	-- second poster at the back left
	local r2 = poster(g, "PosterGG", Vector3.new(-37, 13, Z0), Vector3.new(0, 0, 1), 5, 7, C.black)
	gradient(r2, Color3.fromRGB(20, 200, 160), Color3.fromRGB(20, 60, 120), 90)
	text(r2, "GG", UDim2.fromScale(0.1, 0.15), UDim2.fromScale(0.8, 0.45), C.white)
	text(r2, "GOOD GAME", UDim2.fromScale(0.1, 0.65), UDim2.fromScale(0.8, 0.12), C.white)
	-- wall clock on the +X wall
	local clockPos = Vector3.new(X1 - 0.1, 14, -18)
	deco(g, "Clock", Vector3.new(0.2, 3, 3), CFrame.new(clockPos), C.white, Enum.Material.SmoothPlastic,
		{ shape = Enum.PartType.Cylinder })
	local face = CFrame.lookAt(clockPos, clockPos + Vector3.new(-1, 0, 0))
	deco(g, "ClockHandH", Vector3.new(0.14, 0.9, 0.04), face * CFrame.new(0, 0.35, -0.13), C.black)
	deco(g, "ClockHandM", Vector3.new(0.1, 1.2, 0.04), face * CFrame.new(0.52, 0.3, -0.13) * CFrame.Angles(0, 0, math.rad(-60)), C.black)
	flush(g)
end

-- Front wall: door, dresser with TV + console, bookcase -------------------------------------------
do
	local g = group("FrontWall")
	-- door (decorative) facing -Z into the room
	local doorX = -28
	deco(g, "DoorFrame", Vector3.new(6.2, 10.6, 0.3), Vector3.new(doorX, FLOOR_Y + 5.3, Z1 - 0.15), C.white)
	part(g, "Door", Vector3.new(5.4, 10.1, 0.25), Vector3.new(doorX, FLOOR_Y + 5.05, Z1 - 0.3), Color3.fromRGB(190, 170, 150), Enum.Material.Wood)
	deco(g, "DoorKnob", Vector3.new(0.4, 0.4, 0.4), Vector3.new(doorX + 2.1, FLOOR_Y + 4.8, Z1 - 0.55), Color3.fromRGB(200, 200, 205), Enum.Material.Metal,
		{ shape = Enum.PartType.Ball })
	local doorPoster = poster(g, "DoorPoster", Vector3.new(doorX, FLOOR_Y + 7, Z1 - 0.43), Vector3.new(0, 0, -1), 2.8, 2.2, C.black)
	gradient(doorPoster, Color3.fromRGB(255, 220, 60), Color3.fromRGB(255, 160, 40), 90)
	text(doorPoster, "KEEP OUT\nGAMING", UDim2.fromScale(0.05, 0.1), UDim2.fromScale(0.9, 0.8), C.black)

	-- dresser + TV + console
	local dx, dz = 24, Z1 - 1.6
	part(g, "Dresser", Vector3.new(9, 3.2, 3), Vector3.new(dx, FLOOR_Y + 1.6, dz), C.wood, Enum.Material.Wood)
	for i = 0, 1 do
		for j = 0, 1 do
			deco(g, "DresserDrawer" .. (i * 2 + j + 1), Vector3.new(4.2, 1.3, 0.06), Vector3.new(dx - 2.2 + j * 4.4, FLOOR_Y + 0.85 + i * 1.5, dz - 1.53), C.darkWood, Enum.Material.Wood)
		end
	end
	local tvPos = Vector3.new(dx, FLOOR_Y + 3.2 + 2.6, dz + 0.4)
	local tvCf = CFrame.lookAt(tvPos, tvPos + Vector3.new(0, 0, -1))
	deco(g, "TVStand", Vector3.new(2.2, 0.15, 1.2), Vector3.new(dx, FLOOR_Y + 3.275, dz + 0.4), C.black)
	deco(g, "TVNeck", Vector3.new(0.4, 0.8, 0.3), Vector3.new(dx, FLOOR_Y + 3.75, dz + 0.5), C.black)
	part(g, "TV", Vector3.new(7.4, 4.2, 0.3), tvCf, C.black)
	local tvScreen = deco(g, "TVScreen", Vector3.new(7.0, 3.9, 0.05), tvCf * CFrame.new(0, 0, -0.17), C.black)
	local tv = frame(gui(tvScreen, true), UDim2.fromScale(0, 0), UDim2.fromScale(1, 1), C.black)
	gradient(tv, Color3.fromRGB(80, 180, 255), Color3.fromRGB(60, 200, 120), 90)
	frame(tv, UDim2.fromScale(0, 0.7), UDim2.fromScale(1, 0.3), Color3.fromRGB(70, 160, 60))
	frame(tv, UDim2.fromScale(0.2, 0.55), UDim2.fromScale(0.08, 0.15), Color3.fromRGB(230, 60, 60))
	frame(tv, UDim2.fromScale(0.5, 0.45), UDim2.fromScale(0.2, 0.06), Color3.fromRGB(200, 120, 60))
	frame(tv, UDim2.fromScale(0.78, 0.5), UDim2.fromScale(0.1, 0.2), Color3.fromRGB(40, 140, 40))
	deco(g, "Console", Vector3.new(2.4, 0.5, 1.6), Vector3.new(dx + 3.2, FLOOR_Y + 3.45, dz - 0.3), C.white)
	neon(g, "ConsoleLight", Vector3.new(1.8, 0.05, 0.05), Vector3.new(dx + 3.2, FLOOR_Y + 3.5, dz - 1.12), C.blue)
	deco(g, "Controller", Vector3.new(1.2, 0.25, 0.7), CFrame.new(dx - 3.2, FLOOR_Y + 3.33, dz - 0.6) * CFrame.Angles(0, math.rad(15), 0), C.black)

	-- bookcase on the -X wall near the front corner
	local bx, bz = X0 + 1.3, 4
	local bh, bw = 9, 6
	part(g, "Bookcase", Vector3.new(2.6, bh, bw), Vector3.new(bx, FLOOR_Y + bh / 2, bz), C.darkWood, Enum.Material.Wood)
	local palette = { C.pink, C.blue, Color3.fromRGB(255, 200, 60), C.leaf, C.purple, C.white, Color3.fromRGB(230, 90, 60) }
	for s = 0, 2 do
		local sy = FLOOR_Y + 1.2 + s * 2.8
		deco(g, "BookcaseShelf" .. (s + 1), Vector3.new(0.2, 0.25, bw - 0.4), Vector3.new(bx + 1.35, sy - 0.12, bz), C.wood, Enum.Material.Wood)
		local z = bz - bw / 2 + 0.6
		for k = 1, 6 do
			local h = 1.6 + ((s * 6 + k) % 3) * 0.3
			deco(g, "BookcaseBook" .. (s * 6 + k), Vector3.new(1.6, h, 0.45), Vector3.new(bx + 0.6, sy + h / 2, z), palette[(s * 6 + k) % #palette + 1])
			z += 0.55
		end
	end
	-- small plant on top
	vcyl(g, "BookcasePlantPot", 1, 1.2, Vector3.new(bx, FLOOR_Y + bh + 0.5, bz + 1.5), C.pot, Enum.Material.SmoothPlastic, { decor = true })
	ellipsoid(g, "BookcasePlant", Vector3.new(1.8, 1.4, 1.8), CFrame.new(bx, FLOOR_Y + bh + 1.6, bz + 1.5), C.leaf, Enum.Material.Grass, { decor = true })

	-- front wall poster
	local fp = poster(g, "PosterArcade", Vector3.new(4, 13, Z1), Vector3.new(0, 0, -1), 10, 5.5, C.black)
	gradient(fp, Color3.fromRGB(60, 20, 120), Color3.fromRGB(200, 40, 140), 0)
	pixels(fp, INVADER, Color3.fromRGB(255, 230, 80), UDim2.fromScale(0.08, 0.2), UDim2.fromScale(0.3, 0.6))
	text(fp, "ARCADE", UDim2.fromScale(0.42, 0.3), UDim2.fromScale(0.52, 0.4), C.white, Enum.Font.Arcade)
	flush(g)
end

-- Player spawn: a small mat in front of the cabinet's entry pad, facing -Z -----------------------
do
	local g = group("Spawn")
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Vector3.new(5, 0.2, 4)
	spawn.CFrame = CFrame.new(0, FLOOR_Y + 0.1, -3) -- identity rotation: faces -Z, toward the table
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.AllowTeamChangeOnTouch = false
	spawn.Duration = 0
	spawn.Color = Color3.fromRGB(70, 50, 110)
	spawn.Material = Enum.Material.Fabric
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.CanCollide = true
	spawn.Parent = g
	flush(g)
end

if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
else
	ChangeHistoryService:SetWaypoint("Build Room")
end

local count = 0
for _, d in ipairs(room:GetDescendants()) do
	if d:IsA("BasePart") then
		count += 1
	end
end
print(("build_room: Workspace.Room built (%d parts)"):format(count))
return count
