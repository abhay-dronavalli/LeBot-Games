-- Pattern Match unit tests. Not part of the game: run in Studio's command bar (or via the MCP
-- execute_luau tool) in Edit mode. Requires clones of the modules, so it never touches the place
-- and never gets stale cached module code. Returns "N passed, M failed" plus one line per check.

local RS = game:GetService("ReplicatedStorage")

-- Studio's command-bar require cache keeps the first version of a module it loaded this session.
-- ArmTwin.Rig and Core.StateStore require PatternMatch.Config by path, so swap Config for an identical
-- copy first; everything else below is required through clones.
do
	local old = RS.PatternMatch.Config
	local copy = old:Clone()
	old:Destroy()
	copy.Parent = RS.PatternMatch
end

local pm = RS.PatternMatch:Clone()
local Config = require(pm.Config)
local Grid = require(pm.Grid)
local Target = require(pm.Target)

local lines, passed, failed = {}, 0, 0
local function show(v)
	if type(v) == "table" then return "{" .. table.concat(v, ",") .. "}" end
	return tostring(v)
end
local function check(name, got, want)
	local ok = show(got) == show(want)
	if ok then passed += 1 else failed += 1 end
	table.insert(lines, (ok and "PASS " or "FAIL ") .. name .. " -> " .. show(got) .. (ok and "" or ("  (want " .. show(want) .. ")")))
end
local function section(s) table.insert(lines, "-- " .. s) end

local O, S = Config.gridOriginCm, Config.cellSizeCm
-- Table cm for a point a fraction (fc, fr) across a cell; 0.5, 0.5 is the center. Unflipped sheet layout.
local function at(row, col, fc, fr)
	return O.X + (col - 1 + (fc or 0.5)) * S, O.Y + (row - 1 + (fr or 0.5)) * S
end
local nextId = 10
local function block(cell, color, over)
	local row, col = Grid.parseCell(cell)
	local x, y = at(row, col)
	local b = { id = nextId, color = color or "red", x = x, y = y, z = 0, yaw = 15, level = 0,
		held = false, visible = true, zone = "play" }
	nextId += 1
	for k, v in pairs(over or {}) do b[k] = v end
	return b
end
-- { A1 = "red", B2 = {"red", "teal"}, ... } -> blocks at each cell center; a list is a tower bottom to top,
-- with level and z set the way the core reports them.
local function blocksFor(map)
	local blocks = {}
	for cell, tower in pairs(map) do
		if type(tower) == "string" then tower = { tower } end
		for i, color in ipairs(tower) do table.insert(blocks, block(cell, color, { level = i - 1, z = (i - 1) * 3.5 })) end
	end
	return blocks
end
-- Same map -> live grid, plus any extra blocks in `more`
local function live(map, more)
	local blocks = blocksFor(map)
	for _, b in ipairs(more or {}) do table.insert(blocks, b) end
	return Grid.liveGridFrom(blocks)
end
-- A target with single-color cells, written as { A1 = "red" }, in Target's tower form
local function towers(map)
	local t = {}
	for cell, tower in pairs(map) do t[cell] = type(tower) == "string" and { tower } or tower end
	return t
end

table.insert(lines, string.format("Config: origin=(%.3f, %.3f) cm, cell=%.3f cm, tolerance=%.1f, flipX=%s, flipY=%s",
	O.X, O.Y, S, Config.cellTolerance, tostring(Config.flipX), tostring(Config.flipY)))

section("names")
local cells = Grid.allCells()
check("allCells count / first / last", #cells .. " " .. cells[1] .. " " .. cells[#cells], "12 A1 C4")
check("parseCell C4 -> row, col", table.concat({ Grid.parseCell("C4") }, ","), "3,4")
check("parseCell D1 (no row D)", Grid.parseCell("D1"), nil)
check("parseCell A5 (no column 5)", Grid.parseCell("A5"), nil)

section("1. block at a cell center")
check("cellOf(5.3975, 5.0805) A1 center literal", Grid.cellOf(5.3975, 5.0805), "A1")
check("B2 center", Grid.cellOf(at(2, 2)), "B2")
check("C4 center", Grid.cellOf(at(3, 4)), "C4")
check("row A, column 4 (x toward tag 1)", Grid.cellOf(at(1, 4)), "A4")
check("row C, column 1 (y toward tag 3)", Grid.cellOf(at(3, 1)), "C1")

section("2. block on a cell edge")
check("x = 8.255, column 1/2 boundary", Grid.cellOf(8.255, select(2, at(1, 1))), nil)
check("y = 7.938, row A/B boundary", Grid.cellOf(at(1, 1), 7.938), nil)
check("10% into A1 (outer 15%)", Grid.cellOf(at(1, 1, 0.10)), nil)
check("20% into A1 (inside middle 70%)", Grid.cellOf(at(1, 1, 0.20)), "A1")

section("3. off-grid block")
check("x = 1.0, before column 1", Grid.cellOf(1.0, select(2, at(1, 1))), nil)
check("x = 27, past column 4", Grid.cellOf(27, select(2, at(1, 1))), nil)
check("y = 1.0, before row A", Grid.cellOf(at(1, 1), 1.0), nil)
check("y = 21, past row C", Grid.cellOf(at(1, 1), 21), nil)

local flat = { A1 = "red", B2 = "teal", C3 = "yellow" }
local target = towers(flat)
table.insert(lines, "-- target used below: A1=red, B2=teal, C3=yellow")
check("compare exact match .clear", Target.compare(target, live(flat), {}).clear, true)

section("4. compare with one extra block (purple on A4)")
local r = Target.compare(target, live({ A1 = "red", B2 = "teal", C3 = "yellow", A4 = "purple" }), {})
check(".clear", r.clear, false); check(".extra", r.extra, { "A4" }); check(".missing", r.missing, {})
check(".wrong", r.wrong, {}); check(".blocked", r.blocked, {}); check(".doubled", r.doubled, {})

section("5. compare with a block on a vanished cell (red on vanished B4)")
r = Target.compare(target, live({ A1 = "red", B2 = "teal", C3 = "yellow", B4 = "red" }), { B4 = true })
check(".clear", r.clear, false); check(".blocked", r.blocked, { "B4" }); check(".extra", r.extra, {})
check(".missing", r.missing, {}); check(".wrong", r.wrong, {})
check("same, block removed from B4 .clear", Target.compare(target, live(flat), { B4 = true }).clear, true)

section("6. compare missing / wrong")
r = Target.compare(target, live({ A1 = "red", B2 = "purple" }), {})
check(".missing", r.missing, { "C3" }); check(".wrong", r.wrong, { "B2" }); check(".clear", r.clear, false)

section("7. cellOfBlock with plan.md-shaped blocks at B2 center")
check("play zone, on table", Grid.cellOfBlock(block("B2")), "B2")
check("visible=false (marker hidden, still tracked)", Grid.cellOfBlock(block("B2", "red", { visible = false })), "B2")
check("zone=\"tray\"", Grid.cellOfBlock(block("B2", "red", { zone = "tray" })), nil)
check("zone=false (not tray)", Grid.cellOfBlock(block("B2", "red", { zone = false })), "B2")
check("held=true, z=8", Grid.cellOfBlock(block("B2", "red", { held = true, z = 8, visible = false })), nil)
check("level=1 gets its cell (stack rule decides)", Grid.cellOfBlock(block("B2", "red", { level = 1, z = 3.5 })), "B2")
check("on column 2/3 boundary", Grid.cellOfBlock(block("B2", "red", { x = O.X + 2 * S })), nil)

section("8. flipX / flipY (A1 center on the table)")
local ax, ay = at(1, 1)
local bx, by = at(2, 2)
Config.flipX = true
check("flipX: A1 -> A4", Grid.cellOf(ax, ay), "A4")
check("flipX: B2 -> B3", Grid.cellOf(bx, by), "B3")
Config.flipX, Config.flipY = false, true
check("flipY: A1 -> C1", Grid.cellOf(ax, ay), "C1")
check("flipY: B2 -> B2 (middle row)", Grid.cellOf(bx, by), "B2")
Config.flipX = true
check("both: A1 -> C4", Grid.cellOf(ax, ay), "C4")
check("both: edge still off grid", Grid.cellOf(8.255, ay), nil)
Config.flipX, Config.flipY = false, false
check("flags off again: A1 -> A1", Grid.cellOf(ax, ay), "A1")

section("9. live grid levels: a block's level field picks its slot in the cell")
local stackOnTarget = live(flat, { block("A1", "red", { level = 1, z = 3.5, visible = true }) })
check("live A1: level 0 / level 1 colors", stackOnTarget.A1[0][1] .. " / " .. stackOnTarget.A1[1][1], "red / red")
check("levelsOf(A1)", Grid.levelsOf(stackOnTarget.A1), { 0, 1 })
local floating = live({}, { block("B3", "teal", { level = 1, z = 3.5 }) })
check("level 1 with nothing at level 0 stays at level 1", tostring(floating.B3[0]) .. " / " .. floating.B3[1][1], "nil / teal")
check("level 2.7 / -1 / nil read as 2 / 0 / 0", Grid.levelOf({ level = 2.7 }) .. Grid.levelOf({ level = -1 }) .. Grid.levelOf({}), "200")
r = Target.compare(target, stackOnTarget, {})
check("red on red A1 (target wants a single) .clear", r.clear, false); check(".extra", r.extra, { "A1" })
check(".wrong", r.wrong, {}); check(".missing", r.missing, {}); check(".doubled (a stack is not a double)", r.doubled, {})
check(".problemLevels A1 = level 1 only", tostring(r.problemLevels.A1[0]) .. " " .. tostring(r.problemLevels.A1[1]), "nil true")
r = Target.compare(target, live(flat, { block("A4", "red"), block("A4", "teal", { level = 1 }) }), {})
check("stack on non-target A4 .extra", r.extra, { "A4" }); check(".doubled", r.doubled, {})
check(".problemLevels A4 = both levels", tostring(r.problemLevels.A4[0]) .. " " .. tostring(r.problemLevels.A4[1]), "true true")
r = Target.compare(target, live(flat, { block("B3", "teal", { level = 1, z = 3.5 }) }), {})
check("floating level 1 block on non-target B3 .extra", r.extra, { "B3" })

section("10. doubles rule: 2+ blocks at one cell and level")
r = Target.compare(target, live(flat, { block("A1", "red", { x = select(1, at(1, 1, 0.3)) }) }), {})
check("two reds in A1 .clear", r.clear, false); check(".doubled", r.doubled, { "A1" })
check(".wrong", r.wrong, {}); check(".missing", r.missing, {}); check(".extra", r.extra, {})
r = Target.compare(target, live(flat, { block("B4", "red"), block("B4", "teal") }), {})
check("double on non-target B4 .doubled", r.doubled, { "B4" }); check(".extra", r.extra, { "B4" })
check("describe()", Target.describe(r), "clear=false missing={} wrong={} extra={B4} blocked={} doubled={B4}")

section("11. generate(n, maxHeight): n blocks, towers no taller than maxHeight, never above the global cap")
local bad = 0
local tallestSeen = {}
for _ = 1, 500 do
	for _, n in ipairs({ 3, 4, 5, 12 }) do
		for _, maxHeight in ipairs({ 1, 2, 3 }) do
			local t = Target.generate(n, maxHeight)
			local count, tallest = Target.count(t)
			for cell, tower in pairs(t) do
				if not Grid.parseCell(cell) or #tower == 0 then bad += 1 end
				for _, color in ipairs(tower) do
					if not Config.colors[color] then bad += 1 end
				end
			end
			if count ~= n then bad += 1 end
			if tallest > math.min(maxHeight, Config.maxStackGlobal) then bad += 1 end
			tallestSeen[maxHeight] = math.max(tallestSeen[maxHeight] or 0, tallest)
		end
	end
end
check("6000 patterns, problems", bad, 0)
check("tallest tower seen with maxHeight 1 / 2 / 3 (global cap 2)", tallestSeen[1] .. tallestSeen[2] .. tallestSeen[3], "122")
check("Config: maxStackByRound / maxStackGlobal / stackChance", table.concat(Config.maxStackByRound, ",") .. " " .. Config.maxStackGlobal .. " " .. Config.stackChance, "1,2,2 2 0.5")
check("same seed, same towers", (function()
	local a, b = Target.generate(5, 2, Random.new(42)), Target.generate(5, 2, Random.new(42))
	for cell, tower in pairs(a) do
		if table.concat(tower, "/") ~= table.concat(b[cell] or {}, "/") then return false end
	end
	return Target.count(a) == Target.count(b)
end)(), true)
local stacked = 0
for _ = 1, 200 do
	local _, tallest = Target.count(Target.generate(4, 2))
	if tallest == 2 then stacked += 1 end
end
check("stackChance 0.5: 200 four-block round 2 targets, some with a tower, some flat", stacked > 20 and stacked < 200, true)
check("24 blocks at maxHeight 2 fills every cell twice", select(1, Target.count(Target.generate(24, 2))), 24)
check("13 blocks at maxHeight 1 is refused", pcall(Target.generate, 13, 1), false)

section("11b. compare with towers (target A1=red, B2=red/teal, C3=yellow)")
local tall = towers({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow" })
r = Target.compare(tall, live({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow" }), {})
check("correct 2-tower .clear", r.clear, true)
r = Target.compare(tall, live({ A1 = "red", B2 = { "teal", "red" }, C3 = "yellow" }), {})
check("wrong order (teal under red) .clear", r.clear, false); check(".wrong", r.wrong, { "B2" })
check(".extra / .missing / .doubled", { #r.extra, #r.missing, #r.doubled }, { 0, 0, 0 })
r = Target.compare(tall, live({ A1 = "red", B2 = "red", C3 = "yellow" }), {})
check("missing top block .clear", r.clear, false); check(".missing", r.missing, { "B2" }); check(".wrong", r.wrong, {})
r = Target.compare(tall, live({ A1 = { "red", "red" }, B2 = { "red", "teal" }, C3 = "yellow" }), {})
check("extra block on top of a correct single .clear", r.clear, false); check(".extra", r.extra, { "A1" })
check(".problemLevels A1 = level 1", tostring(r.problemLevels.A1[0]) .. " " .. tostring(r.problemLevels.A1[1]), "nil true")
r = Target.compare(tall, live({ A1 = "red", B2 = { "red", "teal", "purple" }, C3 = "yellow" }), {})
check("third block on a 2-tower .extra (level 2 >= global cap)", r.extra, { "B2" }); check(".wrong / .missing", { #r.wrong, #r.missing }, { 0, 0 })
check(".problemLevels B2 = level 2 only", tostring(r.problemLevels.B2[1]) .. " " .. tostring(r.problemLevels.B2[2]), "nil true")
r = Target.compare(tall, live({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow" },
	{ block("B2", "teal", { level = 1, z = 3.5, x = select(1, at(2, 2, 0.3)) }) }), {})
check("doubled level 1 on B2 .doubled", r.doubled, { "B2" }); check(".clear", r.clear, false); check(".extra", r.extra, {})
check(".problemLevels B2 = level 1 only", tostring(r.problemLevels.B2[0]) .. " " .. tostring(r.problemLevels.B2[1]), "nil true")
r = Target.compare(tall, live({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow", C4 = { "red", "teal" } }), {})
check("tower on non-target C4 .extra", r.extra, { "C4" }); check(".clear", r.clear, false)
check(".problemLevels C4 = both levels", tostring(r.problemLevels.C4[0]) .. " " .. tostring(r.problemLevels.C4[1]), "true true")
r = Target.compare(tall, live({ A1 = "red", B2 = { "red", "purple" }, C3 = "yellow" }), {})
check("wrong color on top only .wrong", r.wrong, { "B2" }); check(".missing", r.missing, {})
r = Target.compare(tall, live({ A1 = "red", C3 = "yellow" }, { block("B2", "teal", { level = 1, z = 3.5 }) }), {})
check("top block reported with nothing under it: .missing (level 0)", r.missing, { "B2" }); check(".wrong", r.wrong, {}); check(".extra", r.extra, {})
r = Target.compare(tall, live({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow" }), { B2 = true })
check("tower on a vanished cell .blocked", r.blocked, { "B2" }); check(".missing (blocked cells skip it)", r.missing, {})
check(".problemLevels B2 = both levels", tostring(r.problemLevels.B2[0]) .. " " .. tostring(r.problemLevels.B2[1]), "true true")
check("Target.count(tall)", table.concat({ Target.count(tall) }, ","), "4,2")

section("12. worldPositionOf on an 8 x 1 x 6 base at (0, 5, 0): row A at +Z, column 1 at -X")
local base = Instance.new("Part")
base.Size = Vector3.new(8, 1, 6)
base.CFrame = CFrame.new(0, 5, 0)
check("A1", tostring(Grid.worldPositionOf("A1", base)), "-3, 5.5, 2")
check("A4", tostring(Grid.worldPositionOf("A4", base)), "3, 5.5, 2")
check("C1", tostring(Grid.worldPositionOf("C1", base)), "-3, 5.5, -2")
check("C4", tostring(Grid.worldPositionOf("C4", base)), "3, 5.5, -2")
check("D1 / A5", tostring(Grid.worldPositionOf("D1", base)) .. " / " .. tostring(Grid.worldPositionOf("A5", base)), "nil / nil")
base:Destroy()

section("13. StateStore stand-in API (edit mode, fake loop off)")
local Store = require(RS.Core.StateStore:Clone())
local s0 = Store.get()
check("initial t / seq / #blocks", s0.t .. " " .. s0.seq .. " " .. #s0.blocks, "state 0 0")
local fired
Store.changed:Connect(function(s) fired = s.seq end)
Store.update({ t = "state", seq = 7, ts = 0, arm = s0.arm, tip = s0.tip, blocks = { block("B2") } })
local waitedFrom = os.clock() -- signal handlers are deferred; give it up to 1 s
repeat task.wait() until fired ~= nil or os.clock() - waitedFrom > 1
check("update() fires changed with new seq", fired, 7)
check("get() returns updated blocks", #Store.get().blocks, 1)

section("14. built boards")
local cab = workspace:FindFirstChild("PatternCabinet")
if cab then
	local names = {}
	for _, c in ipairs(cab.TargetBoard:GetChildren()) do
		if Grid.parseCell(c.Name) then table.insert(names, c.Name) end
	end
	table.sort(names)
	check("TargetBoard tiles", names, cells)
	local liveA1 = Grid.worldPositionOf("A1", cab.LiveBoard)
	check("LiveBoard tile A1 sits on Grid.worldPositionOf(A1)", (cab.LiveBoard.A1.Position - liveA1).Magnitude < 0.11, true)

	section("14b. Apprentice styling: wooden table and slabs, paper sheet, ink grid, tags, arm colors")
	local tbl = cab:FindFirstChild("Table")
	check("one Table model: wooden Top plus 4 Legs", tbl ~= nil and tbl.Top.Material == Enum.Material.Wood and tbl.Top.Color == Color3.fromHex("7a5638")
		and #tbl:GetChildren() == 5, true)
	local lb = cab.LiveBoard
	check("boards sit on the table top", tbl ~= nil and math.abs((lb.Slab.Position.Y - lb.Slab.Size.Y / 2) - (tbl.Top.Position.Y + tbl.Top.Size.Y / 2)) < 0.001, true)
	check("Slab: wood, darker than the table", lb.Slab.Material == Enum.Material.Wood and lb.Slab.Color ~= tbl.Top.Color
		and lb.Slab.Color.R < tbl.Top.Color.R, true)
	check("Paper: off-white SmoothPlastic, wider than the grid on every side", lb.Paper.Color == Color3.fromHex("f7f6f2")
		and lb.Paper.Material == Enum.Material.SmoothPlastic
		and lb.Paper.Size.Z > lb.Base.Size.X and lb.Paper.Size.X > lb.Base.Size.Z, true)
	check("Base is the black ink layer, exactly the grid's size, on the paper", lb.Base.Color == Color3.fromHex("111111")
		and lb.Base.Size.X == Config.gridCols * Config.boardCellStuds and lb.Base.Size.Z == Config.gridRows * Config.boardCellStuds
		and math.abs((lb.Base.Position.Y - lb.Base.Size.Y / 2) - (lb.Paper.Position.Y + lb.Paper.Size.Y / 2)) < 0.001, true)
	check("cell tiles: paper colored, 0.2 stud ink gaps, gray label top-left", lb.B2.Color == Color3.fromHex("f7f6f2")
		and math.abs(lb.B2.Size.X - (Config.boardCellStuds - 0.2)) < 0.001
		and lb.B2.SurfaceGui.TextLabel.TextColor3 == Color3.fromHex("555555")
		and lb.B2.SurfaceGui.TextLabel.Position.X.Scale < 0.1 and lb.B2.SurfaceGui.TextLabel.Position.Y.Scale < 0.1, true)
	check("tiles turned +90 so labels read upright from the row C side", math.abs(lb.B2.Orientation.Y - 90) < 0.001, true)
	local tags = 0
	for _, c in ipairs(lb:GetChildren()) do
		if c.Name == "Tag" and c.Color == Color3.fromHex("111111") then tags += 1 end
	end
	check("four corner tags on each paper sheet", tags .. "/" .. (function()
		local n = 0
		for _, c in ipairs(cab.TargetBoard:GetChildren()) do if c.Name == "Tag" then n += 1 end end
		return n
	end)(), "4/4")
	check("TARGET / LIVE labels on the slabs' row A edge, dark text", cab.TargetBoard.Slab.SurfaceGui.TextLabel.Text == "TARGET"
		and lb.Slab.SurfaceGui.TextLabel.Text == "LIVE" and lb.Slab.SurfaceGui.Face == Enum.NormalId.Back
		and lb.Slab.SurfaceGui.TextLabel.TextColor3.R < 0.2, true)
	check("no Stand under the boards any more", lb:FindFirstChild("Stand") == nil and cab.TargetBoard:FindFirstChild("Stand") == nil, true)
	local twin = lb:FindFirstChild("ArmTwin")
	check("arm twin: off-white links, dark joints", twin ~= nil and twin.UpperArm.Color == Color3.fromHex("e9e6df")
		and twin.ElbowHub.Color == Color3.fromHex("2a2d33") and twin.Base.Material == Enum.Material.SmoothPlastic, true)
	check("arm twin stands on the LiveBoard's apron (slab top)", twin ~= nil
		and math.abs((twin.Base.Position.Y - twin.Base.Size.Y / 2) - (lb.Slab.Position.Y + lb.Slab.Size.Y / 2)) < 0.001, true)
	check("Config colors are the Apprentice palette", Config.colors.red == Color3.fromHex("e2383f") and Config.colors.teal == Color3.fromHex("16a59b")
		and Config.colors.purple == Color3.fromHex("8a5cc7") and Config.colors.skyblue == Color3.fromHex("62bdea"), true)
	local blockMesh = RS.PatternMatch:FindFirstChild("BlockMesh")
	table.insert(lines, "     (BlockMesh template: " .. (blockMesh and blockMesh.MeshId or "missing, plain Parts") .. ")")
else
	check("Workspace.PatternCabinet exists", false, true)
end

local Game = require(pm.Game)
local TargetBoard = require(pm.TargetBoard)

section("15. Hard reveal timing: Game.revealAt(seconds since round start), show 5 s / hide 5 s")
local function reveal(t)
	local phase, left = Game.revealAt(t)
	return string.format("%s %.2f", phase, left)
end
check("0 s (round start)", reveal(0), "show 5.00")
check("4.9 s", reveal(4.9), "show 0.10")
check("5.0 s boundary", reveal(5), "hide 5.00")
check("9.9 s", reveal(9.9), "hide 0.10")
check("10.0 s boundary, next cycle", reveal(10), "show 5.00")
check("17 s", reveal(17), "hide 3.00")
Config.debugFastTimers = true
check("fast timers: 1.25 s boundary", reveal(1.25), "hide 1.25")
Config.debugFastTimers = false

section("16. Game driven by step() on a cloned cabinet (fake store and remote)")
if cab then
	local board = cab:Clone() -- never parented, so the place is untouched
	local fakeBlocks = {}
	local sent = {}
	local fired = {}
	local g = Game.new({
		cabinet = board,
		store = { get = function() return { blocks = fakeBlocks } end },
		core = { fire = function(name, intensity, duration) table.insert(fired, name .. " " .. intensity .. " " .. duration) end },
		ui = { FireAllClients = function(_, p) table.insert(sent, p) end, FireClient = function() end },
	})
	local function steps(n, dt)
		for _ = 1, n do g:step(dt) end
	end

	local tester = { Name = "Tester", UserId = 1 }
	-- Easy game from Idle to round 1: mode select runs out, auto-picks Easy, then the confirmation.
	local function startEasy()
		g:setState("Idle")
		g:start(tester)
		g:step(Config.modeSelectSeconds)
		g:step(Config.modeConfirmSeconds)
	end

	Config.debugForceMode = "hard"
	g:setState("Idle")
	check("start() from Idle", g:start(tester), true)
	check("start() while running is ignored", g:start(tester), false)
	check("debugForceMode=hard skips mode select: mode / state / round", g.mode .. " " .. g.state .. " " .. g.round, "Hard Round 1")
	check("round 1 starts in show, 5 s left", g.revealPhase .. " " .. math.ceil(g.revealLeft), "show 5")
	local tcell, ttower = next(g.target)
	local tcolor = ttower[1]
	check("round 1 (maxStackByRound 1): 3 blocks, all flat", table.concat({ Target.count(g.target) }, ","), "3,1")
	local tblock = board.TargetBoard.Blocks[tcell]
	check("BlockPool: 12 cells x 2 levels of block parts, level 1 one block higher", #board.TargetBoard.Blocks:GetChildren() == 24
		and math.abs((board.TargetBoard.Blocks[tcell .. "_1"].Position - tblock.Position).Y - tblock.Size.Y) < 0.001, true)
	local BlockPool = require(pm.BlockPool)
	check("block is 84% of a cell wide and sits on its tile", math.abs(tblock.Size.X - Config.boardCellStuds * BlockPool.BLOCK_FRACTION) < 0.001
		and math.abs((tblock.Position.Y - tblock.Size.Y / 2) - (board.TargetBoard[tcell].Position.Y + board.TargetBoard[tcell].Size.Y / 2)) < 0.001, true)
	check("block is a rounded-cube MeshPart clone when PatternMatch.BlockMesh exists, else a Part",
		(RS.PatternMatch:FindFirstChild("BlockMesh") ~= nil) == tblock:IsA("MeshPart") and tblock.Material == Enum.Material.SmoothPlastic, true)
	local other
	for _, c in ipairs(cells) do
		if not g.target[c] then other = board.TargetBoard.Blocks[c] break end
	end
	check("show: target block shown in its color", tblock.Transparency == 0 and tblock.Color == Config.colors[tcolor], true)
	check("show: target block outlined", tblock.TargetOutline.Visible, true)
	check("show: non-target cell has no block", other.Transparency == 1 and not other.TargetOutline.Visible, true)
	local neutralTiles = 0
	for _, c in ipairs(cells) do
		if board.TargetBoard[c].Color == TargetBoard.NEUTRAL then neutralTiles += 1 end
	end
	check("all 12 TargetBoard tiles stay neutral", neutralTiles, 12)
	check("target block matches a LiveBoard block (size, material, height above its tile)",
		tblock.Size == board.LiveBoard.Blocks[tcell].Size and tblock.Material == board.LiveBoard.Blocks[tcell].Material
		and math.abs((tblock.Position.Y - board.TargetBoard[tcell].Position.Y) - (board.LiveBoard.Blocks[tcell].Position.Y - board.LiveBoard[tcell].Position.Y)) < 0.001, true)
	steps(19, 0.25) -- 4.75 s
	check("4.75 s: still show, 1 s left on HUD", g.revealPhase .. " " .. sent[#sent].revealTimeLeft, "show 1")
	g:step(0.25) -- 5.0 s
	check("5.0 s: hide", g.revealPhase, "hide")
	check("hide: target block still shown, now gray", tblock.Transparency == 0 and tblock.Color == TargetBoard.HIDDEN, true)
	check("hide: outline stays", tblock.TargetOutline.Visible, true)
	check("hide: non-target cell still has no block", other.Transparency == 1 and not other.TargetOutline.Visible, true)
	check("hide: the tile under it stays neutral", board.TargetBoard[tcell].Color == TargetBoard.NEUTRAL, true)
	check("payload revealPhase / revealTimeLeft", sent[#sent].revealPhase .. " " .. sent[#sent].revealTimeLeft, "hide 5")
	steps(20, 0.25) -- 10.0 s
	check("10.0 s: show again", g.revealPhase, "show")
	steps(20, 0.25) -- 15.0 s, back in hide
	check("15.0 s: hide", g.revealPhase, "hide")

	fakeBlocks = blocksFor(g.target)
	steps(4, 0.25) -- clear held for 1 s
	check("solved during hide -> Intermission", g.state, "Intermission")
	check("intermission: target block in full color", tblock.Transparency == 0 and tblock.Color == Config.colors[tcolor], true)
	check("intermission: no outline, no reveal in payload", tostring(tblock.TargetOutline.Visible) .. " " .. tostring(sent[#sent].revealPhase), "false nil")

	fakeBlocks = {}
	g:step(Config.intermissionSeconds)
	check("round 2 state", g.state .. " " .. g.round, "Round 2")
	check("round 2 reset to show, 5 s left", g.revealPhase .. " " .. math.ceil(g.revealLeft), "show 5")

	section("16b. towers on the boards (round 2 target forced to A1=red, B2=red/teal, C3=yellow, C4=purple)")
	g.target = towers({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow", C4 = "purple" })
	g.targetBoard:show(g.target, false, true)
	local b2lo, b2hi = board.TargetBoard.Blocks.B2, board.TargetBoard.Blocks.B2_1
	check("TargetBoard B2: red below, teal on top, both outlined", b2lo.Color == Config.colors.red and b2hi.Color == Config.colors.teal
		and b2lo.Transparency == 0 and b2hi.Transparency == 0 and b2lo.TargetOutline.Visible and b2hi.TargetOutline.Visible, true)
	check("TargetBoard A1: single, level 1 hidden and not outlined", board.TargetBoard.Blocks.A1.Transparency == 0
		and board.TargetBoard.Blocks.A1_1.Transparency == 1 and not board.TargetBoard.Blocks.A1_1.TargetOutline.Visible, true)
	g.targetBoard:show(g.target, true, true)
	check("hidden phase: both B2 levels gray, outlines stay", b2lo.Color == TargetBoard.HIDDEN and b2hi.Color == TargetBoard.HIDDEN
		and b2lo.TargetOutline.Visible and b2hi.TargetOutline.Visible, true)
	fakeBlocks = blocksFor({ A1 = "red", B2 = { "teal", "red" }, C3 = "yellow", C4 = "purple" }) -- B2 upside down
	steps(8, 0.25)
	check("LiveBoard B2: teal below, red on top", board.LiveBoard.Blocks.B2.Color == Config.colors.teal
		and board.LiveBoard.Blocks.B2_1.Color == Config.colors.red and board.LiveBoard.Blocks.B2_1.Transparency == 0, true)
	check("wrong order does not clear after 2 s", g.state .. " " .. Target.describe(Target.compare(g.target, g.liveGrid, {})),
		"Round clear=false missing={} wrong={B2} extra={} blocked={} doubled={}")
	fakeBlocks = blocksFor(g.target)
	steps(5, 0.25)
	check("right order clears", g.state, "Intermission")
	fakeBlocks = {}
	g:step(Config.intermissionSeconds)
	check("round 3 target: 5 blocks, towers up to 2", (function()
		local n, tallest = Target.count(g.target)
		return n == 5 and tallest <= 2
	end)(), true)

	section("17. Easy mode unchanged, LiveBoard problem highlight on the specific block")
	Config.debugForceMode = nil
	startEasy()
	check("debugForceMode=nil: auto-picked Easy, round 1", g.mode .. " " .. g.state, "Easy Round")
	local ecell, etower = next(g.target)
	local ecolor = etower[1]
	local eblock = board.TargetBoard.Blocks[ecell]
	check("easy: no reveal phase, no outline", tostring(g.revealPhase) .. " " .. tostring(eblock.TargetOutline.Visible), "nil false")
	check("easy: target block shown in its color", eblock.Transparency == 0 and eblock.Color == Config.colors[ecolor], true)
	local easyBlocks = 0
	for _, c in ipairs(cells) do
		if board.TargetBoard.Blocks[c].Transparency == 0 then easyBlocks += 1 end
	end
	check("easy: one target block per target cell, round 1 = 3", easyBlocks, 3)

	local free = {}
	for _, c in ipairs(cells) do
		if not g.target[c] then table.insert(free, c) end
	end
	fakeBlocks = blocksFor(g.target)
	table.insert(fakeBlocks, block(free[1], "red"))                       -- extra
	table.insert(fakeBlocks, block(free[2], "red"))                       -- double...
	table.insert(fakeBlocks, block(free[2], "teal", { x = select(1, at(Grid.parseCell(free[2]))) + 1 }))
	table.insert(fakeBlocks, block(ecell, "purple", { level = 1 }))       -- stack on a correct target cell
	g:step(0.25)
	local function litBlocks()
		local lit = {}
		for _, p in ipairs(board.LiveBoard.Blocks:GetChildren()) do
			if p.ProblemHighlight.Visible then table.insert(lit, p.Name) end
		end
		table.sort(lit)
		return lit
	end
	local want = { free[1], free[2], ecell .. "_1" }
	table.sort(want)
	check("extra + double (level 0) + stacked block (level 1) outlined, not the correct block under the stack", litBlocks(), want)
	fakeBlocks = blocksFor(g.target)
	g:step(0.25)
	check("problems removed -> highlights cleared", litBlocks(), {})

	local PatternEvents = require(pm.PatternEvents)

	section("18. vanish cell selection")
	local rng = Random.new(7)
	local badPicks, maxPicked = 0, 0
	for _ = 1, 300 do
		local tgt = Target.generate(rng:NextInteger(3, 5), 2, rng)
		local occupied = {}
		for _, c in ipairs(cells) do
			if not tgt[c] and rng:NextNumber() < 0.4 then occupied[c] = "red" end
		end
		local lg = live(occupied)
		local picked = PatternEvents.pickVanishCells(tgt, lg, {}, 2, rng)
		maxPicked = math.max(maxPicked, #picked)
		local seen = {}
		for _, c in ipairs(picked) do
			if tgt[c] or lg[c] or seen[c] then badPicks += 1 end
			seen[c] = true
		end
	end
	check("300 random boards: picks on a target, an occupied cell, or twice", badPicks, 0)
	check("never more than 2 cells", maxPicked <= 2, true)
	local fullBoard = {}
	for _, c in ipairs(cells) do fullBoard[c] = "red" end
	check("no empty non-target cell -> nothing picked", PatternEvents.pickVanishCells(towers({ A1 = "red" }), live(fullBoard), {}, 2, rng), {})
	local allButB2 = {}
	for _, c in ipairs(cells) do allButB2[c] = c ~= "B2" or nil end
	check("already vanished cells are not picked again", PatternEvents.pickVanishCells({}, {}, allButB2, 2, rng), { "B2" })

	section("19. vanish in a round: sticky rule, blocked compare, white outline")
	Config.events = { "vanish" }
	Config.debugEventEvery = 4
	fakeBlocks = {}
	startEasy()
	steps(7, 0.25) -- 1.75 s
	check("1.75 s: no event yet", tostring(sent[#sent].event), "nil")
	g:step(0.25) -- 2.0 s: warning, 2 s before the 4 s mark
	check("2.0 s: vanish warning, 2 s", sent[#sent].event.name .. " " .. sent[#sent].event.phase .. " " .. sent[#sent].event.timeLeft, "vanish warning 2")
	steps(8, 0.25) -- 4.0 s
	check("4.0 s: vanish active", g.events.current.phase, "active")
	local vanishedNow = sent[#sent].vanishedCells
	local onTarget = 0
	for _, c in ipairs(vanishedNow) do if g.target[c] then onTarget += 1 end end
	check("1-2 cells vanished, none on the target", #vanishedNow >= 1 and #vanishedNow <= 2 and onTarget == 0, true)
	local v1, v2 = vanishedNow[1], vanishedNow[2]
	check("vanished tile transparent, label hidden", board.LiveBoard[v1].Transparency == 1 and not board.LiveBoard[v1].SurfaceGui.Enabled, true)
	check("TargetBoard unchanged", board.TargetBoard[v1].Transparency, 0)

	fakeBlocks = blocksFor(g.target)
	table.insert(fakeBlocks, block(v1, "red"))
	steps(8, 0.25) -- 6.0 s: target solved, but a block sits on a vanished cell
	check("solved + block on a vanished cell: still Round", g.state, "Round")
	check("compare reports it as blocked", Target.compare(g.target, g.liveGrid, g.events.vanished).blocked, { v1 })
	check("white outline on the blocked cell's block", board.LiveBoard.Blocks[v1].ProblemHighlight.Visible, true)
	steps(20, 0.25) -- 11.0 s: the 6 s vanish timer ran out at 10 s
	check("timer over, block still there: cell stays vanished", board.LiveBoard[v1].Transparency, 1)
	if v2 then
		check("the other vanished cell (no block) came back", board.LiveBoard[v2].Transparency, 0)
	end
	check("round still not cleared", g.state, "Round")

	fakeBlocks = blocksFor(g.target)
	g:step(0.25)
	check("block removed: cell comes back", board.LiveBoard[v1].Transparency .. " " .. table.concat(sent[#sent].vanishedCells, ","), "0 ")
	steps(4, 0.25)
	check("then the round clears", g.state, "Intermission")
	check("vanish never calls Core.Events", #fired, 0)

	section("20. scheduler: only during a Round, never the same event twice in a row")
	Config.events = { "vanish", "tremor", "inverted" }
	Config.debugEventEvery = 3
	local baseBefore = board.LiveBoard.Base.CFrame
	local blockBefore = board.LiveBoard.Blocks.A1.CFrame
	table.clear(fired)
	local seq, outside, lastActive = {}, 0, nil
	local function watch()
		local ev = g.events.current
		if ev and g.state ~= "Round" then outside += 1 end
		if ev and ev.phase == "active" and ev ~= lastActive then
			table.insert(seq, ev.name)
			lastActive = ev
		end
	end
	fakeBlocks = {}
	g:setState("Idle")
	g:start(tester)
	for _ = 1, 66 do g:step(0.25); watch() end -- 15 s of ModeSelect + 1.5 s confirmation
	check("ModeSelect: no events, no Core.Events calls", #seq .. " " .. #fired .. " " .. g.state, "0 0 Round")
	for _ = 1, 240 do g:step(0.25); watch() end -- round 1, 60 s, empty grid
	check("round 1 timed out", g.state, "Intermission")
	check("server never moved the boards (tremor shake is client-side)", board.LiveBoard.Base.CFrame == baseBefore and board.LiveBoard.Blocks.A1.CFrame == blockBefore, true)
	for _ = 1, 40 do g:step(0.25); watch() end -- 10 s of Intermission, then round 2 starts
	check("round 2 started, schedule reset", g.state .. " " .. g.round .. " next at " .. g.events.nextAt, "Round 2 next at 3")
	check("no event outside a Round", outside, 0)
	local repeats = 0
	for i = 2, #seq do
		if seq[i] == seq[i - 1] then repeats += 1 end
	end
	check("round 1 ran at least 5 events", #seq >= 5, true)
	check("back-to-back repeats in " .. table.concat(seq, ","), repeats, 0)
	local tremors, inverts, quakes, mirrors = 0, 0, 0, 0
	for _, name in ipairs(seq) do
		if name == "tremor" then tremors += 1 elseif name == "inverted" then inverts += 1 end
	end
	for _, f in ipairs(fired) do
		if f == "earthquake 0.5 4" then quakes += 1 elseif f == "mirror 1 8" then mirrors += 1 end
	end
	check("Core.Events: earthquake 0.5 4 per tremor, mirror 1 8 per inverted", quakes .. "/" .. tremors .. " " .. mirrors .. "/" .. inverts,
		tremors .. "/" .. tremors .. " " .. inverts .. "/" .. inverts)

	section("21. tremor board shake (BoardShake, run on clients) restores every part exactly")
	local BoardShake = require(pm.BoardShake)
	local baseStart = board.LiveBoard.Base.CFrame
	local tileStart = board.TargetBoard.C4.CFrame
	local targetBlockStart = board.TargetBoard.Blocks.B2.CFrame
	local twinPart = board.LiveBoard:FindFirstChild("ArmTwin") and board.LiveBoard.ArmTwin:FindFirstChild("UpperArm")
	local twinStart = twinPart and twinPart.CFrame
	local shake = BoardShake.start({ board.TargetBoard, board.LiveBoard })
	local moved, twinMoved = false, false
	for _ = 1, 10 do
		task.wait()
		if board.LiveBoard.Base.CFrame ~= baseStart then moved = true end
		if twinPart and twinPart.CFrame ~= twinStart then twinMoved = true end
	end
	table.insert(lines, "     (boards moved while shaking: " .. tostring(moved) .. ", arm twin moved with them: " .. tostring(twinMoved) .. ")")
	shake:stop()
	check("after stop: LiveBoard.Base and TargetBoard.C4 exactly restored",
		board.LiveBoard.Base.CFrame == baseStart and board.TargetBoard.C4.CFrame == tileStart, true)
	check("after stop: TargetBoard block B2 exactly restored too", board.TargetBoard.Blocks.B2.CFrame == targetBlockStart, true)
	if twinPart then
		check("after stop: the twin's (unanchored) UpperArm is back within 0.001 studs",
			(twinPart.Position - twinStart.Position).Magnitude < 0.001, true)
	end

	section("22. mode select: only the starter picks, only during ModeSelect, only once")
	local alice, bob = { Name = "Alice", UserId = 101 }, { Name = "Bob", UserId = 202 }
	Config.debugForceMode = nil
	Config.debugEventEvery = nil
	fakeBlocks = {}
	g:setState("Idle")
	check("Alice starts a game", g:start(alice), true)
	check("state | chooser | HUD message", g.state .. " | " .. sent[#sent].chooser .. " | " .. sent[#sent].message,
		"ModeSelect | Alice | Alice is choosing a mode")
	check("Bob can't pick", g:pick(bob, "hard"), false)
	check("an unknown choice is rejected", g:pick(alice, "medium"), false)
	check("still choosing, no mode yet", g.state .. " " .. tostring(g.mode), "ModeSelect nil")
	check("Alice picks hard", g:pick(alice, "hard"), true)
	check("payload: confirming, mode, message", tostring(sent[#sent].confirming) .. " " .. sent[#sent].mode .. " | " .. sent[#sent].message,
		"true Hard | HARD MODE")
	check("a second pick is rejected", g:pick(alice, "easy"), false)
	steps(5, 0.25) -- 1.25 s of the 1.5 s confirmation
	check("confirmation still showing at 1.25 s", g.state, "ModeSelect")
	g:step(0.25)
	check("then round 1 starts in Hard", g.state .. " " .. g.round .. " " .. g.mode, "Round 1 Hard")
	check("a pick during the round is rejected", g:pick(alice, "easy"), false)
	g:setState("Idle")
	g:start(alice)
	steps(59, 0.25) -- 14.75 s
	check("14.75 s: no pick yet", g.state .. " " .. tostring(g.mode), "ModeSelect nil")
	g:step(0.25)
	check("15 s: auto-picks Easy and confirms", g.mode .. " " .. tostring(sent[#sent].confirming) .. " " .. sent[#sent].message, "Easy true EASY MODE")
	Config.debugForceMode = "easy"
	g:setState("Idle")
	g:start(alice)
	check("debugForceMode=easy skips the screen", g.state .. " " .. g.mode, "Round Easy")
	Config.debugForceMode = nil
	g:setState("Idle")

	section("23. spinning a board keeps tiles and blocks on their cells")
	local BoardSpinner = require(pm.BoardSpinner)
	g.liveBoard:render({ block("A1", "red"), block("B3", "teal"), block("C4", "yellow") })
	local function offCells(boardModel)
		boardModel = boardModel or board.LiveBoard
		local bad = 0
		for _, c in ipairs(cells) do
			local tile = boardModel[c]
			local d = tile.Position - Grid.worldPositionOf(c, boardModel)
			local e = boardModel.Blocks[c].Position - tile.Position
			local f = boardModel.Blocks[c .. "_1"].Position - tile.Position
			if Vector3.new(d.X, 0, d.Z).Magnitude > 0.01 or Vector3.new(e.X, 0, e.Z).Magnitude > 0.01
				or Vector3.new(f.X, 0, f.Z).Magnitude > 0.01 then bad += 1 end
		end
		return bad
	end
	local function waitIdle(spinner, limit)
		local from = os.clock()
		repeat task.wait() until not spinner:busy() or os.clock() - from > limit
		return os.clock() - from
	end
	local liveSpinner = BoardSpinner.new(board.LiveBoard)
	local look0, a1Start = board.LiveBoard.Base.CFrame.LookVector, board.LiveBoard.A1.Position
	liveSpinner:request()
	waitIdle(liveSpinner, 2)
	check("1 spin: base turned 90 degrees", math.abs(board.LiveBoard.Base.CFrame.LookVector:Dot(look0)) < 0.001, true)
	check("1 spin: tiles on Grid.worldPositionOf, block parts on their tiles (cells off)", offCells(), 0)
	check("1 spin: A1 / B3 / C4 blocks still shown in their colors",
		board.LiveBoard.Blocks.A1.Transparency == 0 and board.LiveBoard.Blocks.A1.Color == Config.colors.red
		and board.LiveBoard.Blocks.B3.Color == Config.colors.teal and board.LiveBoard.Blocks.C4.Color == Config.colors.yellow, true)
	liveSpinner:request()
	liveSpinner:request()
	liveSpinner:request()
	waitIdle(liveSpinner, 4)
	check("3 more queued spins run one after another: back to the start", board.LiveBoard.Base.CFrame.LookVector:Dot(look0) > 0.9999
		and (board.LiveBoard.A1.Position - a1Start).Magnitude < 0.001, true)
	check("after 4 spins: cells off", offCells(), 0)
	liveSpinner:destroy()

	g.targetBoard:show(towers({ A1 = "red", C3 = "teal" }), false, false)
	local shakingNow = true
	local targetSpinner = BoardSpinner.new(board.TargetBoard, { isShaking = function() return shakingNow end })
	local tlook0 = board.TargetBoard.Base.CFrame.LookVector
	targetSpinner:request()
	task.wait(0.6)
	check("during a tremor the spin waits", board.TargetBoard.Base.CFrame.LookVector:Dot(tlook0) > 0.9999, true)
	shakingNow = false
	local took = waitIdle(targetSpinner, 3)
	check("tremor over: the spin runs, after the 0.5 s margin", math.abs(board.TargetBoard.Base.CFrame.LookVector:Dot(tlook0)) < 0.001
		and took >= BoardSpinner.AFTER_SHAKE_SECONDS + BoardSpinner.SPIN_SECONDS - 0.05, true)
	check("TargetBoard spin: target blocks stay on their tiles (cells off)", offCells(board.TargetBoard), 0)
	check("TargetBoard spin: A1 / C3 target blocks still shown, B2 still empty",
		board.TargetBoard.Blocks.A1.Color == Config.colors.red and board.TargetBoard.Blocks.C3.Color == Config.colors.teal
		and board.TargetBoard.Blocks.A1.Transparency == 0 and board.TargetBoard.Blocks.B2.Transparency == 1, true)
	if board.LiveBoard:FindFirstChild("ArmTwin") then
		local twinSpinner = BoardSpinner.new(board.LiveBoard)
		local baseRel = board.LiveBoard.Base.CFrame:ToObjectSpace(board.LiveBoard.ArmTwin.Base.CFrame)
		twinSpinner:request()
		waitIdle(twinSpinner, 2)
		local baseRelAfter = board.LiveBoard.Base.CFrame:ToObjectSpace(board.LiveBoard.ArmTwin.Base.CFrame)
		check("LiveBoard spin carries the arm twin (same offset from the board's Base)",
			(baseRel.Position - baseRelAfter.Position).Magnitude < 0.001, true)
		twinSpinner:destroy()
	end
	targetSpinner:destroy()
	board:Destroy()
end

section("24. arm twin forward kinematics (ArmTwin.Rig / Driver; rest pose = horizontal reach forward)")
local twinTemplate = RS:FindFirstChild("ArmTwin")
if twinTemplate then
	local twinCopy = twinTemplate:Clone() -- Driver finds Rig through script.Parent
	local Rig = require(twinCopy.Rig)
	local Driver = require(twinCopy.Driver)
	local L = Config.twinLinksCm
	local reach = L.upperArm + L.forearm + L.wrist + L.gripper
	local shoulderY = L.baseHeight + L.shoulderHeight
	local function tipCm(arm, tuning)
		return Rig.forward(Driver.rigAngles(arm, tuning), true).Position
	end
	local function near(v, x, y, z)
		return (v - Vector3.new(x, y, z)).Magnitude < 0.01
	end
	local sin, cos = math.sin, math.cos
	table.insert(lines, string.format("     (links cm: shoulder height %.1f, reach from shoulder %.1f; scale %.4f studs/cm)", shoulderY, reach, Rig.studsPerCm()))
	check("all joints 0: tip straight ahead at shoulder height", near(tipCm({}), 0, shoulderY, -reach), true)
	check("pan +90: tip a quarter turn left around the base", near(tipCm({ shoulder_pan = 90 }), -reach, shoulderY, 0), true)
	check("pan -90: a quarter turn right", near(tipCm({ shoulder_pan = -90 }), reach, shoulderY, 0), true)
	check("lift +90: arm points straight up", near(tipCm({ shoulder_lift = 90 }), 0, shoulderY + reach, 0), true)
	check("lift +30: tip in the vertical plane, raised by reach*sin30", near(tipCm({ shoulder_lift = 30 }), 0, shoulderY + reach * sin(math.rad(30)), -reach * cos(math.rad(30))), true)
	check("elbow -90: forearm+wrist+gripper hang straight down from the elbow",
		near(tipCm({ elbow_flex = -90 }), 0, shoulderY - (L.forearm + L.wrist + L.gripper), -L.upperArm), true)
	check("wrist_flex +90 only moves the hand", near(tipCm({ wrist_flex = 90 }), 0, shoulderY + L.wrist + L.gripper, -(L.upperArm + L.forearm)), true)
	check("wrist_roll alone leaves the tip where it is (it's on the roll axis)", near(tipCm({ wrist_roll = 123 }), 0, shoulderY, -reach), true)
	check("pan +90 then lift +30 keep the tip in the rotated plane",
		near(tipCm({ shoulder_pan = 90, shoulder_lift = 30 }), -reach * cos(math.rad(30)), shoulderY + reach * sin(math.rad(30)), 0), true)
	local flipped = table.clone(Config.twinJoints)
	flipped.shoulder_lift = { sign = -1, offset = 0 }
	check("sign -1 on shoulder_lift: lift +30 now goes down", tipCm({ shoulder_lift = 30 }, flipped).Y < shoulderY, true)
	flipped.shoulder_pan = { sign = -1, offset = 0 }
	check("sign -1 on shoulder_pan: pan +90 turns right instead", near(tipCm({ shoulder_pan = 90 }, flipped), reach, shoulderY, 0), true)
	local offs = table.clone(Config.twinJoints)
	offs.shoulder_pan = { sign = 1, offset = 90 }
	check("offset 90 on shoulder_pan: real 0 reads as +90", near(tipCm({}, offs), -reach, shoulderY, 0), true)
	local ga = Driver.rigAngles({ gripper = 100 }).gripper
	check("gripper 100 -> fully open, 0 -> closed, 150 clamps", ga == Rig.GRIPPER_OPEN and Driver.rigAngles({ gripper = 0 }).gripper == 0
		and Driver.rigAngles({ gripper = 150 }).gripper == Rig.GRIPPER_OPEN, true)
	check("scale: studs per cm = boardCellStuds / cellSizeCm", math.abs(Rig.studsPerCm() - Config.boardCellStuds / Config.cellSizeCm) < 1e-9, true)

	local motorCount = 0
	for _, d in ipairs(twinTemplate:GetDescendants()) do
		if d:IsA("Motor6D") then motorCount += 1 end
	end
	check("ReplicatedStorage.ArmTwin has the six Motor6Ds", motorCount, 6)
	local tipAtt = twinTemplate:FindFirstChild("Tip", true)
	check("built rig: Tip attachment sits on the FK rest tip (studs)",
		tipAtt ~= nil and (twinTemplate:GetPivot():PointToWorldSpace(Rig.forward({}).Position) - tipAtt.WorldPosition).Magnitude < 0.01, true)
	check("built rig: only the Base is anchored", (function()
		for _, d in ipairs(twinTemplate:GetDescendants()) do
			if d:IsA("BasePart") and d.Anchored ~= (d.Name == "Base") then return false end
		end
		return true
	end)(), true)
else
	check("ReplicatedStorage.ArmTwin exists", false, true)
end

return string.format("%d passed, %d failed\n", passed, failed) .. table.concat(lines, "\n")
