-- Pattern Match unit tests. Not part of the game: run in Studio's command bar (or via the MCP
-- execute_luau tool) in Edit mode. Requires clones of the modules, so it never touches the place
-- and never gets stale cached module code. Returns "N passed, M failed" plus one line per check.
-- The boards and the room are read from the arcade mode's Map (ServerStorage.Modes.PatternMatch.Map);
-- section 33 runs the mode itself (Start / Finished / Stop) in Edit mode, with fake players.

local RS = game:GetService("ReplicatedStorage")

-- Studio's command-bar require cache keeps the first version of a module it loaded this session.
-- ArmTwin.Rig / Stick and Core.StateStore require PatternMatch.Config and Grid by path, so swap those for
-- identical copies first; everything else below is required through clones.
-- Core.StateStore requires ArmTwin.Rig and Driver by path too.
for _, path in ipairs({ { "PatternMatch", "Config" }, { "PatternMatch", "Grid" }, { "ArmTwin", "Rig" }, { "ArmTwin", "Driver" } }) do
	local old = RS:FindFirstChild(path[1]) and RS[path[1]]:FindFirstChild(path[2])
	if old then
		local copy = old:Clone()
		old:Destroy()
		copy.Parent = RS[path[1]]
	end
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

local O, S = Config.gridOriginMm, Config.cellSizeMm
-- Sheet mm for a point a fraction (fc, fr) across a cell; 0.5, 0.5 is the center. Unflipped sheet layout.
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
		for i, color in ipairs(tower) do table.insert(blocks, block(cell, color, { level = i - 1, z = (i - 1) * 48 })) end
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

table.insert(lines, string.format("Config: origin=(%.3f, %.3f) mm, cell=%.3f mm, tolerance=%.1f, flipX=%s, flipY=%s",
	O.X, O.Y, S, Config.cellTolerance, tostring(Config.flipX), tostring(Config.flipY)))

section("names")
local cells = Grid.allCells()
check("allCells count / first / last", #cells .. " " .. cells[1] .. " " .. cells[#cells], "12 A1 C4")
check("parseCell C4 -> row, col", table.concat({ Grid.parseCell("C4") }, ","), "3,4")
check("parseCell D1 (no row D)", Grid.parseCell("D1"), nil)
check("parseCell A5 (no column 5)", Grid.parseCell("A5"), nil)

section("1. block at a cell center")
check("cellOf(53.975, 50.8) A1 center literal (mm)", Grid.cellOf(53.975, 50.8), "A1")
check("B2 center", Grid.cellOf(at(2, 2)), "B2")
check("C4 center", Grid.cellOf(at(3, 4)), "C4")
check("row A, column 4 (x toward tag 1)", Grid.cellOf(at(1, 4)), "A4")
check("row C, column 1 (y toward tag 3)", Grid.cellOf(at(3, 1)), "C1")

section("2. block on a cell edge")
check("x = 82.55, column 1/2 boundary", Grid.cellOf(82.55, select(2, at(1, 1))), nil)
check("y = 79.375, row A/B boundary", Grid.cellOf(at(1, 1), 79.375), nil)
check("10% into A1 (outer 15%)", Grid.cellOf(at(1, 1, 0.10)), nil)
check("20% into A1 (inside middle 70%)", Grid.cellOf(at(1, 1, 0.20)), "A1")

section("3. off-grid block")
check("x = 10, before column 1", Grid.cellOf(10, select(2, at(1, 1))), nil)
check("x = 270, past column 4", Grid.cellOf(270, select(2, at(1, 1))), nil)
check("y = 10, before row A", Grid.cellOf(at(1, 1), 10), nil)
check("y = 210, past row C", Grid.cellOf(at(1, 1), 210), nil)

local flat = { A1 = "red", B2 = "teal", C3 = "yellow" }
local target = towers(flat)
table.insert(lines, "-- target used below: A1=red, B2=teal, C3=yellow")
check("compare exact match .clear", Target.compare(target, live(flat), {}).clear, true)

section("4. compare with one extra block (purple on A4)")
local r = Target.compare(target, live({ A1 = "red", B2 = "teal", C3 = "yellow", A4 = "purple" }), {})
check(".clear", r.clear, false); check(".extra", r.extra, { "A4" }); check(".missing", r.missing, {})
check(".wrong", r.wrong, {}); check(".doubled", r.doubled, {})
check("no blocked list (no vanishing cells any more)", tostring(r.blocked), "nil")

section("5b. misread colors (not in Config.colors) count as wrong blocks, outlined")
check("Target.isMisread: green / grey / red / skyblue", tostring(Target.isMisread("green")) .. tostring(Target.isMisread("grey"))
	.. tostring(Target.isMisread("red")) .. tostring(Target.isMisread("skyblue")), "truetruefalsefalse")
r = Target.compare(target, live({ A1 = "green", B2 = "teal", C3 = "yellow" }), {})
check("green on target cell A1: wrong, outlined, not clear", Target.describe(r) .. " outline " .. tostring(r.problemLevels.A1 and r.problemLevels.A1[0]),
	"clear=false missing={} wrong={A1} extra={} doubled={} outline true")
r = Target.compare(target, live({ A1 = "red", B2 = "teal", C3 = "yellow", B3 = "pink" }), {})
check("pink on non-target B3: wrong (not extra), outlined, not clear", Target.describe(r) .. " outline " .. tostring(r.problemLevels.B3 and r.problemLevels.B3[0]),
	"clear=false missing={} wrong={B3} extra={} doubled={} outline true")
r = Target.compare(towers({ B2 = { "red", "teal" } }), live({ B2 = { "red", "white" } }), {})
check("white on top of a tower: wrong at that level", Target.describe(r) .. " " .. tostring(r.problemLevels.B2 and r.problemLevels.B2[1]),
	"clear=false missing={} wrong={B2} extra={} doubled={} true")

section("6. compare missing / wrong")
r = Target.compare(target, live({ A1 = "red", B2 = "purple" }), {})
check(".missing", r.missing, { "C3" }); check(".wrong", r.wrong, { "B2" }); check(".clear", r.clear, false)

section("7. cellOfBlock with plan.md-shaped blocks at B2 center")
check("play zone, on table", Grid.cellOfBlock(block("B2")), "B2")
check("visible=false, age 0 (arm over it): still counts", Grid.cellOfBlock(block("B2", "red", { visible = false, age = 0 })), "B2")
check("visible=false, age 1.9 (< staleBlockSeconds 2): still counts", Grid.cellOfBlock(block("B2", "red", { visible = false, age = 1.9 })), "B2")
check("visible=false, age 2.5: stale, ignored", Grid.cellOfBlock(block("B2", "red", { visible = false, age = 2.5 })), nil)
check("visible=false, no age field (fake data): counts", Grid.cellOfBlock(block("B2", "red", { visible = false })), "B2")
check("visible=true, age 5 (buried under a stack): counts", Grid.cellOfBlock(block("B2", "red", { visible = true, age = 5 })), "B2")
check("zone=\"tray\"", Grid.cellOfBlock(block("B2", "red", { zone = "tray" })), nil)
check("zone=false (not tray)", Grid.cellOfBlock(block("B2", "red", { zone = false })), "B2")
check("held=true, z=80", Grid.cellOfBlock(block("B2", "red", { held = true, z = 80, visible = true })), nil)
check("level=1 gets its cell (stack rule decides)", Grid.cellOfBlock(block("B2", "red", { level = 1, z = 48 })), "B2")
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
check("describe()", Target.describe(r), "clear=false missing={} wrong={} extra={B4} doubled={B4}")

section("11. generate(n, maxHeight): n blocks, towers no taller than maxHeight, never above the global cap")
Config.uniqueColorsPerTicket = false -- placement only here (n up to 12 is more than the 6 colors); 11a has colors
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
check("Config: shift / interval / rail / blocks / stack ramp / bonus / global cap",
	string.format("%d %d-%d %d %d-%d %.1f-%.1f %d %d", Config.shiftSeconds, Config.ticketIntervalMin, Config.ticketIntervalMax,
		Config.ticketRailMax, Config.ticketBlocksMin, Config.ticketBlocksMax, Config.stackChanceStart, Config.stackChanceEnd,
		Config.ticketTimeBonus, Config.maxStackGlobal), "180 12-20 4 2-4 0.2-0.6 3 2")
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
check("default stack chance (stackChanceStart): 200 four-block targets, some with a tower, some flat", stacked > 20 and stacked < 200, true)
local always, never = 0, 0
for _ = 1, 100 do
	local _, a = Target.count(Target.generate(3, 2, nil, 1))
	local _, b = Target.count(Target.generate(3, 2, nil, 0))
	if a == 2 then always += 1 end
	if b == 1 then never += 1 end
end
check("stackChance argument: 1 always stacks, 0 never does", always .. " " .. never, "100 100")
check("24 blocks at maxHeight 2 fills every cell twice", select(1, Target.count(Target.generate(24, 2))), 24)
check("13 blocks at maxHeight 1 is refused", pcall(Target.generate, 13, 1), false)

section("11a. uniqueColorsPerTicket: no color twice in a pattern, towers included")
check("default: off (core perception names repeated colors)", Config.uniqueColorsPerTicket, false)
Config.uniqueColorsPerTicket = true
do
	local function repeats(target)
		local seen, dup = {}, false
		for _, tower in pairs(target) do
			for _, color in ipairs(tower) do
				if seen[color] then dup = true end
				seen[color] = true
			end
		end
		return dup
	end
	local rng = Random.new(5)
	local dupPatterns, sameTower, towers2, sizes = 0, 0, 0, {}
	for _ = 1, 600 do
		local n = rng:NextInteger(Config.ticketBlocksMin, Config.ticketBlocksMax)
		local t = Target.generate(n, Config.maxStackGlobal, rng, rng:NextNumber())
		if repeats(t) then dupPatterns += 1 end
		for _, tower in pairs(t) do
			if #tower == 2 then
				towers2 += 1
				if tower[1] == tower[2] then sameTower += 1 end
			end
		end
		sizes[Target.count(t) == n] = true
	end
	check("600 tickets: no repeated color; 2-high towers seen, none of one color; every ticket keeps its n",
		dupPatterns .. " " .. tostring(towers2 > 50) .. " " .. sameTower .. " " .. tostring(sizes[true] and not sizes[false]), "0 true 0 true")
	check("all-stacked (stackChance 1, n 6): six blocks, six colors", (function()
		local t = Target.generate(6, 2, Random.new(9), 1)
		return Target.count(t) .. " " .. tostring(repeats(t))
	end)(), "6 false")
	check("n above the palette is capped at #colors (12 asked -> 6 blocks)", (Target.count(Target.generate(12, 2, Random.new(3), 0.5))), 6)
	local saved = Config.colors
	Config.colors = { red = saved.red, teal = saved.teal, yellow = saved.yellow }
	check("three colors left in Config.colors: a 4-block ticket comes out as 3 different colors", (function()
		local t = Target.generate(4, 2, Random.new(4), 0.5)
		return Target.count(t) .. " " .. tostring(repeats(t))
	end)(), "3 false")
	Config.colors = saved
	Config.uniqueColorsPerTicket = false
	local anyDup = false
	local r2 = Random.new(5)
	for _ = 1, 300 do
		if repeats(Target.generate(4, 2, r2, 0.5)) then anyDup = true end
	end
	check("uniqueColorsPerTicket = false: colors may repeat again", anyDup, true)
	Config.uniqueColorsPerTicket = false -- the default
end

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
check("Target.count(tall)", table.concat({ Target.count(tall) }, ","), "4,2")

section("12. worldPositionOf on an 8 x 1 x 6 base at (0, 5, 0): row A at +Z, column 1 at +X")
local base = Instance.new("Part")
base.Size = Vector3.new(8, 1, 6)
base.CFrame = CFrame.new(0, 5, 0)
check("A1", tostring(Grid.worldPositionOf("A1", base)), "3, 5.5, 2")
check("A4", tostring(Grid.worldPositionOf("A4", base)), "-3, 5.5, 2")
check("C1", tostring(Grid.worldPositionOf("C1", base)), "3, 5.5, -2")
check("C4", tostring(Grid.worldPositionOf("C4", base)), "-3, 5.5, -2")
check("D1 / A5", tostring(Grid.worldPositionOf("D1", base)) .. " / " .. tostring(Grid.worldPositionOf("A5", base)), "nil / nil")
base:Destroy()

section("13. StateStore stand-in API (edit mode, fake loop off)")
local Store = require(RS.Core.StateStore:Clone())
local s0 = Store.get()
check("initial t / seq / #blocks", s0.t .. " " .. s0.seq .. " " .. #s0.blocks, "state 0 0")
check("initial arm is nil (no arm data yet: the twin rests)", s0.arm, nil)
local fired
Store.changed:Connect(function(s) fired = s.seq end)
Store.update({ t = "state", seq = 7, ts = 0, arm = s0.arm, tip = s0.tip, blocks = { block("B2") } })
local waitedFrom = os.clock() -- signal handlers are deferred; give it up to 1 s
repeat task.wait() until fired ~= nil or os.clock() - waitedFrom > 1
check("update() fires changed with new seq", fired, 7)
check("get() returns updated blocks", #Store.get().blocks, 1)

section("14. built boards (in the mode's Map)")
local boardView, VIEW_OK -- set in section 14, reused in section 23
local modeFolder = game:GetService("ServerStorage"):FindFirstChild("Modes") and game:GetService("ServerStorage").Modes:FindFirstChild("PatternMatch")
local mapTemplate = modeFolder and modeFolder:FindFirstChild("Map")
local cab = mapTemplate and mapTemplate:FindFirstChild("PatternCabinet")
if cab then
	local names = {}
	for _, c in ipairs(cab.TargetBoard:GetChildren()) do
		if Grid.parseCell(c.Name) then table.insert(names, c.Name) end
	end
	table.sort(names)
	check("TargetBoard tiles", names, cells)
	-- How a board reads for someone at its row C edge looking toward row A, from world positions and
	-- the board's own facing (so it also holds after a spin). Returns a short report string.
	boardView = function(boardModel)
		local base = boardModel.Base
		local look = (boardModel.A1.Position - boardModel.C1.Position) * Vector3.new(1, 0, 1)
		look = look.Unit -- row C toward row A
		local up = base.CFrame.UpVector
		local right = look:Cross(up)
		local function far(c) return boardModel[c].Position:Dot(look) end
		local function rightOf(c) return boardModel[c].Position:Dot(right) end
		local corners = (far("A1") > far("C1") and rightOf("A1") < rightOf("A4") and "A1 far-left" or "A1 wrong")
			.. ", " .. (far("A4") > far("C4") and rightOf("A4") > rightOf("A1") and "A4 far-right" or "A4 wrong")
			.. ", " .. (far("C1") < far("A1") and rightOf("C1") < rightOf("C4") and "C1 near-left" or "C1 wrong")
			.. ", " .. (far("C4") < far("A4") and rightOf("C4") > rightOf("C1") and "C4 near-right" or "C4 wrong")
		local labels = {}
		local upright = true
		for _, c in ipairs(boardModel:GetChildren()) do
			if c.Name == "ColumnLabel" then
				table.insert(labels, c)
				-- A Top-face SurfaceGui's up is the part's -X and its right is the part's -Z.
				local textUp = c.CFrame:VectorToWorldSpace(Vector3.new(-1, 0, 0))
				local textRight = c.CFrame:VectorToWorldSpace(Vector3.new(0, 0, -1))
				if textUp:Dot(look) < 0.99 or textRight:Dot(right) < 0.99 then upright = false end
			end
		end
		table.sort(labels, function(a, b) return a.Position:Dot(right) < b.Position:Dot(right) end)
		local text = ""
		for _, l in ipairs(labels) do text ..= l.SurfaceGui.TextLabel.Text end
		local nearest = labels[1] and labels[1].Position:Dot(look) < far("C1")
		return corners .. "; border reads " .. text .. (upright and ", upright" or ", NOT upright")
			.. (nearest and " on the row C edge" or " off the row C edge")
	end
	VIEW_OK = "A1 far-left, A4 far-right, C1 near-left, C4 near-right; border reads 1234, upright on the row C edge"
	check("TargetBoard from the row C side", boardView(cab.TargetBoard), VIEW_OK)
	check("LiveBoard from the row C side", boardView(cab.LiveBoard), VIEW_OK)
	check("rendering only: sheet-mm data mapping unchanged (A1 / A4 / C1 corners of the sheet)",
		Grid.cellOf(at(1, 1)) .. Grid.cellOf(at(1, 4)) .. Grid.cellOf(at(3, 1)), "A1A4C1")
	check("arm twin centered on the LiveBoard's width, on the row A side", cab.LiveBoard:FindFirstChild("ArmTwin") ~= nil
		and math.abs(cab.LiveBoard.ArmTwin.Base.Position.X - cab.LiveBoard.Base.Position.X) < 0.001
		and cab.LiveBoard.ArmTwin.Base.Position.Z > cab.LiveBoard.A1.Position.Z, true)
	check("SpinClick only on the TargetBoard", tostring(cab.TargetBoard:FindFirstChild("SpinClick") ~= nil) .. " "
		.. tostring(cab.LiveBoard:FindFirstChildWhichIsA("ClickDetector", true) ~= nil), "true false")
	local liveA1 = Grid.worldPositionOf("A1", cab.LiveBoard)
	check("LiveBoard tile A1 sits on Grid.worldPositionOf(A1)", (cab.LiveBoard.A1.Position - liveA1).Magnitude < 0.11, true)

	section("14b. wooden boards on the table, arm colors, bedroom")
	local tbl = cab:FindFirstChild("Table")
	check("one Table model: wooden Top plus 4 Legs", tbl ~= nil and tbl.Top.Material == Enum.Material.Wood and tbl.Top.Color == Color3.fromHex("7a5638")
		and #tbl:GetChildren() == 5, true)
	local lb, tb = cab.LiveBoard, cab.TargetBoard
	check("boards sit on the table top", tbl ~= nil and math.abs((lb.Slab.Position.Y - lb.Slab.Size.Y / 2) - (tbl.Top.Position.Y + tbl.Top.Size.Y / 2)) < 0.001
		and math.abs((tb.Slab.Position.Y - tb.Slab.Size.Y / 2) - (tbl.Top.Position.Y + tbl.Top.Size.Y / 2)) < 0.001, true)
	check("Slab: wood, lighter than the table so the board stands out", lb.Slab.Material == Enum.Material.Wood
		and lb.Slab.Color.R + lb.Slab.Color.G + lb.Slab.Color.B > tbl.Top.Color.R + tbl.Top.Color.G + tbl.Top.Color.B, true)
	local chess = true
	for _, board in ipairs({ lb, tb }) do
		for _, c in ipairs(cells) do
			local row, col = Grid.parseCell(c)
			local nextCol = col < Config.gridCols and Grid.cellName(row, col + 1) or Grid.cellName(row, col - 1)
			local nextRow = row < Config.gridRows and Grid.cellName(row + 1, col) or Grid.cellName(row - 1, col)
			if board[c].Color == board[nextCol].Color or board[c].Color == board[nextRow].Color
				or board[c].Color ~= board[(row + col) % 2 == 0 and "A1" or "A2"].Color or board[c].Material ~= Enum.Material.Wood then
				chess = false
			end
		end
	end
	check("12 inlaid wood squares in two alternating tones (chessboard), both boards", chess and lb.A1.Color ~= lb.A2.Color, true)
	check("squares: 0.2 stud grooves, no labels inside", math.abs(lb.B2.Size.X - (Config.boardCellStuds - 0.2)) < 0.001
		and lb.B2:FindFirstChildOfClass("SurfaceGui") == nil, true)
	check("Base is the dark groove layer, exactly the grid's size, under the squares", lb.Base.Color.R < 0.15
		and lb.Base.Size.X == Config.gridCols * Config.boardCellStuds and lb.Base.Size.Z == Config.gridRows * Config.boardCellStuds
		and math.abs((lb.B2.Position.Y - lb.B2.Size.Y / 2) - (lb.Base.Position.Y + lb.Base.Size.Y / 2)) < 0.001, true)
	check("no paper, ink sheet or tag squares left", lb:FindFirstChild("Paper") == nil and lb:FindFirstChild("Tag") == nil
		and tb:FindFirstChild("Paper") == nil and tb:FindFirstChild("Tag") == nil, true)
	local function carvedTexts(board, name)
		local list = {}
		for _, c in ipairs(board:GetChildren()) do
			if c.Name == name then table.insert(list, c.SurfaceGui.TextLabel.Text) end
		end
		table.sort(list)
		return table.concat(list, "")
	end
	check("border carvings: rows A,B,C on both sides, columns 1-4", carvedTexts(lb, "RowLabel") .. " " .. carvedTexts(lb, "ColumnLabel")
		.. " | " .. carvedTexts(tb, "RowLabel") .. " " .. carvedTexts(tb, "ColumnLabel"), "AABBCC 1234 | AABBCC 1234")
	local function labelAt(board, name, text)
		for _, c in ipairs(board:GetChildren()) do
			if c.Name == name and c.SurfaceGui.TextLabel.Text == text then return c end
		end
	end
	check("row A carved on the arm side (+Z), row C toward -Z; column 1 at +X (tag 0 side), on the row C border",
		labelAt(lb, "RowLabel", "A").Position.Z > lb.Base.Position.Z + 3 and labelAt(lb, "RowLabel", "C").Position.Z < lb.Base.Position.Z - 3
		and labelAt(lb, "ColumnLabel", "1").Position.X > labelAt(lb, "ColumnLabel", "4").Position.X
		and labelAt(lb, "ColumnLabel", "1").Position.Z < lb.Base.Position.Z - lb.Base.Size.Z / 2, true)
	check("TARGET / LIVE carved in the row A border, gold vs green accents", labelAt(tb, "BoardLabel", "TARGET") ~= nil
		and labelAt(lb, "BoardLabel", "LIVE") ~= nil and labelAt(tb, "BoardLabel", "TARGET").Position.Z > tb.Base.Position.Z
		and tb.Inlay.Color ~= lb.Inlay.Color and tb.Inlay.Color.R > tb.Inlay.Color.B and lb.Inlay.Color.G > lb.Inlay.Color.R, true)
	local twin = lb:FindFirstChild("ArmTwin")
	check("arm twin: off-white links, dark joints", twin ~= nil and twin.UpperArm.Color == Color3.fromHex("e9e6df")
		and twin.ElbowHub.Color == Color3.fromHex("2a2d33") and twin.Base.Material == Enum.Material.SmoothPlastic, true)
	check("arm twin stands on the LiveBoard's apron (slab top)", twin ~= nil
		and math.abs((twin.Base.Position.Y - twin.Base.Size.Y / 2) - (lb.Slab.Position.Y + lb.Slab.Size.Y / 2)) < 0.001, true)
	check("Config colors are the Apprentice palette", Config.colors.red == Color3.fromHex("e2383f") and Config.colors.teal == Color3.fromHex("16a59b")
		and Config.colors.purple == Color3.fromHex("8a5cc7") and Config.colors.skyblue == Color3.fromHex("62bdea"), true)
	local room = mapTemplate:FindFirstChild("Room")
	local mat = room and room:FindFirstChild("Spawn") and room.Spawn:FindFirstChild("Mat")
	check("bedroom built; Baseplate, SpawnLocations, sky island and cabinet floor gone", room ~= nil and workspace:FindFirstChild("Baseplate") == nil
		and mapTemplate:FindFirstChildWhichIsA("SpawnLocation", true) == nil and cab:FindFirstChild("Island") == nil and cab:FindFirstChild("Floor") == nil, true)
	check("the Play pad and its prompt in front of the table's row C side; the StartSpot behind the pad, in prompt range",
		tostring(cab:FindFirstChild("Entry") and cab.Entry:FindFirstChild("PlayPrompt") and cab.Entry.PlayPrompt:IsA("ProximityPrompt")) .. " "
		.. tostring(cab:FindFirstChild("StartSpot") ~= nil and cab.Entry.Position.Z > cab.Table.Top.Position.Z + cab.Table.Top.Size.Z / 2
			and cab.StartSpot.Position.Z > cab.Entry.Position.Z
			and (cab.StartSpot.Position - cab.Entry.Position).Magnitude < cab.Entry.PlayPrompt.MaxActivationDistance - 1), "true true")
	check("the spawn mat is a plain part, near the start spot", mat ~= nil and mat.ClassName == "Part" and (mat.Position - cab.StartSpot.Position).Magnitude < 12, true)
	local scriptsInRoom = 0
	for _, d in ipairs(room and room:GetDescendants() or {}) do
		if d:IsA("LuaSourceContainer") then scriptsInRoom += 1 end
	end
	check("no scripts inside the room's props", scriptsInRoom, 0)
	check("Lighting holds no Pattern Match effect (the depth of field lives under the camera; the arcade owns Lighting)",
		tostring(game:GetService("Lighting"):FindFirstChild("CabinetFocus")), "nil")
	local blockMesh = RS.PatternMatch:FindFirstChild("BlockMesh")
	table.insert(lines, "     (BlockMesh template: " .. (blockMesh and blockMesh.MeshId or "missing, plain Parts") .. ")")
else
	check("ServerStorage.Modes.PatternMatch.Map.PatternCabinet exists", false, true)
end

local Game = require(pm.Game)
local TargetBoard = require(pm.TargetBoard)

section("15a. ticket points and the stack chance ramp")
check("points: empty / one flat / one 2-tower / 2 flat + 1 stacked",
	table.concat({ Game.ticketPoints({}), Game.ticketPoints(towers({ A1 = "red" })), Game.ticketPoints(towers({ A1 = { "red", "teal" } })),
		Game.ticketPoints(towers({ A1 = "red", A2 = { "teal", "yellow" } })) }, ","), "1,2,5,6")
check("stack chance at 0 / half / end / past the end of a 180 s shift",
	string.format("%.2f %.2f %.2f %.2f", Game.stackChanceAt(0, 180), Game.stackChanceAt(90, 180), Game.stackChanceAt(180, 180), Game.stackChanceAt(400, 180)),
	"0.20 0.40 0.60 0.60")

section("15. Hard reveal timing: Game.revealAt(seconds since shift start), show 5 s / hide 5 s")
local function reveal(t)
	local phase, left = Game.revealAt(t)
	return string.format("%s %.2f", phase, left)
end
check("0 s (shift start)", reveal(0), "show 5.00")
check("4.9 s", reveal(4.9), "show 0.10")
check("5.0 s boundary", reveal(5), "hide 5.00")
check("9.9 s", reveal(9.9), "hide 0.10")
check("10.0 s boundary, next cycle", reveal(10), "show 5.00")
check("17 s", reveal(17), "hide 3.00")
Config.debugFastTimers = true
check("fast timers: 1.25 s boundary", reveal(1.25), "hide 1.25")
Config.debugFastTimers = false

section("16. shift: tickets on the rail (Game driven by step() on a cloned cabinet, fake store and remote)")
if cab then
	local board = cab:Clone() -- never parented, so the place is untouched
	local fakeBlocks = {}
	local robotStatus = "mock"
	local sent, changes = {}, {}
	local g = Game.new({
		cabinet = board,
		store = { get = function() return { blocks = fakeBlocks } end, status = function() return robotStatus end },
		ui = { FireAllClients = function(_, p) table.insert(sent, p) end, FireClient = function() end },
		stateChanged = { Fire = function(_, info) table.insert(changes, info) end },
		rng = Random.new(11),
		manualAttract = true, -- the Idle demo only moves when a test advances it
	})
	local function steps(n, dt)
		for _ = 1, n do g:step(dt) end
	end
	local function railIds()
		local list = {}
		for _, t in ipairs(g.tickets) do table.insert(list, t.id) end
		return table.concat(list, ",")
	end
	local function ticketById(id)
		for _, t in ipairs(g.tickets) do if t.id == id then return t end end
	end
	-- Gives a ticket a known pattern (and its points); redraws the TargetBoard if it is the active one.
	local function setPattern(ticket, map)
		ticket.target = towers(map)
		ticket.points = Game.ticketPoints(ticket.target)
		if ticket.id == g.activeId then g:showActive() end
	end
	local tester = { Name = "Tester", UserId = 1 }
	-- Easy shift from Idle: mode select runs out, auto-picks Easy, then the confirmation.
	local function startEasy()
		g:setState("Idle")
		g:start(tester)
		g:step(Config.modeSelectSeconds)
		g:step(Config.modeConfirmSeconds)
	end
	Config.debugForceMode = "easy"
	g:setState("Idle")
	check("start() from Idle", g:start(tester), true)
	check("start() while running is ignored", g:start(tester), false)
	check("debugForceMode=easy: straight into the shift, full timer", g.mode .. " " .. g.state .. " " .. g.timeLeft, "Easy Shift " .. Config.shiftSeconds)
	check("the first ticket arrives at shift start and is active", railIds() .. " active " .. tostring(g.activeId), "1 active 1")
	local t1 = g.tickets[1]
	local t1Blocks, t1Tallest = Target.count(t1.target)
	check("ticket 1: 2-4 blocks, towers up to 2, points from its pattern", t1Blocks >= 2 and t1Blocks <= 4 and t1Tallest <= 2
		and t1.points == Game.ticketPoints(t1.target), true)
	local acell = next(t1.target)
	check("TargetBoard shows the active ticket", board.TargetBoard.Blocks[acell].Transparency == 0
		and board.TargetBoard.Blocks[acell].Color == Config.colors[t1.target[acell][1]], true)
	check("stateChanged: Shift with the active ticket's target", changes[#changes].state .. " " .. tostring(changes[#changes].activeId)
		.. " " .. tostring(changes[#changes].target == t1.target), "Shift 1 true")
	check("payload: rail, active id, points, age, cells", #sent[#sent].tickets .. " " .. sent[#sent].activeId .. " "
		.. sent[#sent].tickets[1].points .. " " .. sent[#sent].tickets[1].age .. " " .. tostring(sent[#sent].tickets[1].cells[acell] ~= nil),
		"1 1 " .. t1.points .. " 0 true")

	section("16a. arrivals: random 12-20 s apart, paused while the rail is full")
	local wait1 = g.arrivalIn
	check("next arrival 12-20 s out", wait1 >= Config.ticketIntervalMin and wait1 <= Config.ticketIntervalMax, true)
	g:step(wait1 - 0.1)
	check("0.1 s before it: still one ticket", railIds(), "1")
	g:step(0.2)
	check("then ticket 2 arrives at the right end; ticket 1 stays active", railIds() .. " active " .. g.activeId, "1,2 active 1")
	check("an arrival never changes the active ticket (payload + one waiting)", sent[#sent].activeId .. " "
		.. require(pm.TicketStack).waitingCount(#sent[#sent].tickets), "1 1")
	check("ticket 2's age on the payload counts from its arrival", sent[#sent].tickets[2].age, 0)
	local guard = 0
	while #g.tickets < Config.ticketRailMax and guard < 10 do
		g:step(g.arrivalIn + 0.01)
		guard += 1
	end
	check("rail fills to 4, oldest first, ticket 1 still active", railIds() .. " active " .. g.activeId, "1,2,3,4 active 1")
	local paused, timeBefore = g.arrivalIn, g.timeLeft
	steps(40, 0.5) -- 20 s with a full rail
	check("full rail: no 5th ticket, the arrival timer is paused", railIds() .. " " .. tostring(g.arrivalIn == paused), "1,2,3,4 true")
	check("the shift timer keeps running meanwhile", math.abs((timeBefore - g.timeLeft) - 20) < 0.01, true)

	section("16b. cycling the ticket stack (Q / R and the < > arrows send TicketCycle -1 / +1)")
	local TicketStack = require(pm.TicketStack)
	local function cycleRun(dirs)
		local seen = {}
		for _, dir in ipairs(dirs) do
			g:cycleTicket(tester, dir)
			table.insert(seen, g.activeId)
		end
		return table.concat(seen, " ")
	end
	check("forward (R / >) from 1 wraps around: 2 3 4 1", cycleRun({ 1, 1, 1, 1 }), "2 3 4 1")
	check("back (Q / <) from 1 wraps around: 4 3 2 1", cycleRun({ -1, -1, -1, -1 }), "4 3 2 1")
	check("the rail order never changes (oldest first)", railIds(), "1,2,3,4")
	g:cycleTicket(tester, 1) -- active 2
	local t2 = ticketById(2)
	local c2 = next(t2.target)
	check("the TargetBoard follows the active ticket", board.TargetBoard.Blocks[c2].Transparency == 0
		and board.TargetBoard.Blocks[c2].Color == Config.colors[t2.target[c2][1]], true)
	check("stateChanged and the payload follow too", changes[#changes].activeId .. " " .. sent[#sent].activeId, "2 2")
	g:cycleTicket(tester, -1) -- back to 1
	check("bad directions are rejected", tostring(g:cycleTicket(tester, 2)) .. " " .. tostring(g:cycleTicket(tester, 0))
		.. " " .. tostring(g:cycleTicket(tester, "next")), "false false false")
	check("Q / R and the arrows map to the same -1 / +1; E (the ProximityPrompt key) does nothing",
		TicketStack.KEYS[Enum.KeyCode.Q] .. " " .. TicketStack.KEYS[Enum.KeyCode.R] .. " " .. tostring(TicketStack.KEYS[Enum.KeyCode.E])
		.. " " .. TicketStack.ARROWS.Prev .. " " .. TicketStack.ARROWS.Next, "-1 1 nil -1 1")
	local hudSource = RS.PatternMatch.Views.Player.PatternHud:FindFirstChildWhichIsA("LocalScript").Source
	check("the HUD wires Q / R and both arrows to one cycle() that fires TicketCycle, with Q / R key hints",
		string.find(hudSource, "TicketStack.KEYS[input.KeyCode]", 1, true) ~= nil
		and string.find(hudSource, "cycle(TicketStack.ARROWS.Prev)", 1, true) ~= nil
		and string.find(hudSource, "cycle(TicketStack.ARROWS.Next)", 1, true) ~= nil
		and string.find(hudSource, "ticketCycle:FireServer(dir)", 1, true) ~= nil
		and string.find(hudSource, 'arrow("Prev", "<", "Q"', 1, true) ~= nil
		and string.find(hudSource, 'arrow("Next", ">", "R"', 1, true) ~= nil
		and string.find(hudSource, "TicketPick", 1, true) == nil, true)
	check("badge: waiting = tickets - 1, '+3 waiting', hidden at 0, at most 3 edges",
		TicketStack.waitingCount(#sent[#sent].tickets) .. " | " .. TicketStack.badgeText(3) .. " | " .. tostring(TicketStack.badgeText(0))
		.. " | " .. TicketStack.pileEdges(1) .. TicketStack.pileEdges(3) .. TicketStack.pileEdges(6), "3 | +3 waiting | nil | 133")
	check("cycledId: one ticket stays put, empty is nil", tostring(TicketStack.cycledId({ 7 }, 7, 1)) .. " " .. tostring(TicketStack.cycledId({}, nil, 1)), "7 nil")

	section("16b2. picking a ticket directly (server API)")
	check("selectTicket(3) makes it active", g:selectTicket(tester, 3), true)
	check("active 3, on the payload and stateChanged", g.activeId .. " " .. sent[#sent].activeId .. " " .. changes[#changes].activeId, "3 3 3")
	check("an unknown ticket or the already active one is rejected", tostring(g:selectTicket(tester, 99)) .. " " .. tostring(g:selectTicket(tester, 3)), "false false")
	setPattern(ticketById(3), { A1 = "red", A2 = { "teal", "yellow" } })
	check("TargetBoard shows ticket 3: A1 red, A2 teal under yellow", board.TargetBoard.Blocks.A1.Color == Config.colors.red
		and board.TargetBoard.Blocks.A2.Color == Config.colors.teal and board.TargetBoard.Blocks.A2_1.Color == Config.colors.yellow
		and board.TargetBoard.Blocks.A2_1.Transparency == 0, true)

	section("16c. completing the active ticket: points, +3 s, oldest becomes active")
	fakeBlocks = blocksFor({ A1 = "red", A2 = { "yellow", "teal" } }) -- A2 upside down
	steps(8, 0.25)
	check("wrong stack order: not completed after 2 s", railIds() .. " score " .. g.score, "1,2,3,4 score 0")
	fakeBlocks = blocksFor({ A1 = "red", A2 = { "teal", "yellow" } })
	local before = g.timeLeft
	steps(3, 0.25)
	check("0.75 s of a match: not yet (hold 1 s)", railIds(), "1,2,3,4")
	g:step(0.25)
	check("1 s: ORDER UP, ticket 3 leaves the rail", railIds(), "1,2,4")
	check("ORDER UP plays the shared celebration: big text, sparkles on both boards, cells flashed white",
		g.celebrate.label.Text .. " | " .. tostring(g.celebrate.gui.Enabled) .. " " .. tostring(g.celebrate.emitters[1].Enabled and g.celebrate.emitters[2].Enabled)
		.. " " .. tostring(board.LiveBoard.B2.Color == g.celebrate.FLASH_COLOR or board.LiveBoard.B2.Color ~= cab.LiveBoard.B2.Color),
		"ORDER UP! +6 | true true true")
	check("points: 1 + 2 flat + 3 stacked = 6", g.score .. " " .. sent[#sent].completedCount, "6 1")
	check("+3 s on the shift timer", math.abs(g.timeLeft - (before - 1 + Config.ticketTimeBonus)) < 0.01, true)
	check("payload orderUp: id / points / bonus", sent[#sent].orderUp.id .. " " .. sent[#sent].orderUp.points .. " " .. sent[#sent].orderUp.bonus, "3 6 3")
	check("the oldest remaining ticket (1) becomes active", g.activeId .. " " .. changes[#changes].activeId, "1 1")
	check("rail not full any more: the arrival timer runs again", (function()
		local a = g.arrivalIn
		g:step(0.25)
		return g.arrivalIn < a
	end)(), true)

	section("16d. reusing blocks: the board already matches part of the next ticket")
	setPattern(ticketById(1), { A1 = "red", B1 = "purple" })
	local keepA1
	for _, b in ipairs(fakeBlocks) do
		if b.color == "red" and Grid.cellOfBlock(b) == "A1" then keepA1 = b end
	end
	fakeBlocks = { keepA1 } -- the A2 tower is cleared away, the red A1 block stays where it is
	g:step(0.25)
	local partial = Target.compare(g:activeTicket().target, g.liveGrid)
	check("A1 already counts: only B1 is missing, nothing extra or wrong", Target.describe(partial),
		"clear=false missing={B1} wrong={} extra={} doubled={}")
	table.insert(fakeBlocks, block("B1", "purple"))
	steps(4, 0.25)
	check("adding B1 completes ticket 1 with the reused A1 block (+3 points)", railIds() .. " score " .. g.score .. " active " .. g.activeId, "2,4 score 9 active 2")

	section("16e. an empty rail gets the next ticket right away")
	g.tickets = { ticketById(2) } -- leave one ticket on the rail
	setPattern(g.tickets[1], { C4 = "orange" })
	fakeBlocks = { block("C4", "orange") }
	steps(4, 0.25)
	local newest = g.tickets[1]
	check("completing the last ticket brings a new one at once, and it is active", #g.tickets .. " " .. tostring(newest.id > 4)
		.. " " .. tostring(g.activeId == newest.id), "1 true true")
	check("its arrival timer starts over (12-20 s)", g.arrivalIn >= Config.ticketIntervalMin and g.arrivalIn <= Config.ticketIntervalMax, true)

	section("16f. shift end")
	g.timeLeft = 0.1
	g:step(0.25)
	check("timer hits 0: Results", g.state, "Results")
	local done = sent[#sent].completed
	check("results payload: tickets completed, points, per-ticket list", #done .. " " .. sent[#sent].score .. " " .. done[1].id .. ":" .. done[1].points
		.. " " .. done[2].id .. ":" .. done[2].points, "3 11 3:6 1:3")
	check("rail and TargetBoard cleared", #sent[#sent].tickets .. " " .. board.TargetBoard.Blocks.A1.Transparency, "0 1")
	g:step(Config.resultsSeconds)
	check("then back to Idle", g.state, "Idle")

	section("16f2. robot OFFLINE: matching freezes, the shift timer keeps running")
	g:start(tester)
	setPattern(g:activeTicket(), { B3 = "red" })
	fakeBlocks = { block("B3", "red") }
	robotStatus = "offline"
	local frozenFrom, frozenId, frozenScore = g.timeLeft, g.activeId, g.score
	steps(12, 0.25)
	check("3 s of an exact match while OFFLINE: not completed", tostring(g.activeId == frozenId) .. " score " .. g.score, "true score " .. frozenScore)
	check("the shift timer kept running", math.abs(g.timeLeft - (frozenFrom - 3)) < 0.01, true)
	check("payload.robot is offline (the badge)", sent[#sent].robot, "offline")
	robotStatus = "mock"
	g:step(0.25)
	check("back online: the 1 s hold starts over", tostring(g.activeId == frozenId), "true")
	steps(4, 0.25)
	check("then ORDER UP", tostring(g.activeId ~= frozenId) .. " " .. tostring(g.score > frozenScore) .. " " .. sent[#sent].robot, "true true mock")

	section("16f2b. repeated colors: a ticket with two reds, and a red/red tower, can be matched")
	setPattern(g:activeTicket(), { A1 = "red", C3 = "red" })
	local twinRedId, twinRedScore = g.activeId, g.score
	fakeBlocks = { block("A1", "red"), block("C3", "red") }
	steps(5, 0.25)
	check("two reds on two cells: ORDER UP", tostring(g.activeId ~= twinRedId) .. " " .. tostring(g.score > twinRedScore), "true true")
	setPattern(g:activeTicket(), { B2 = { "red", "red" } })
	local towerId, towerScore = g.activeId, g.score
	fakeBlocks = blocksFor({ B2 = { "red", "red" } })
	steps(5, 0.25)
	check("a red/red tower: ORDER UP", tostring(g.activeId ~= towerId) .. " " .. tostring(g.score > towerScore), "true true")

	section("16f3. a misread block (green) shows gray and blocks the match")
	setPattern(g:activeTicket(), { B3 = "red" })
	local misreadId, misreadScore = g.activeId, g.score
	fakeBlocks = { block("B3", "green") }
	steps(8, 0.25)
	local b3 = board.LiveBoard.Blocks.B3
	check("green at B3: drawn gray, white outline, not completed after 2 s", string.format("%d,%d,%d %s %s",
		b3.Color.R * 255 + 0.5, b3.Color.G * 255 + 0.5, b3.Color.B * 255 + 0.5, tostring(b3.ProblemHighlight.Visible),
		tostring(g.activeId == misreadId and g.score == misreadScore)), "150,150,150 true true")
	fakeBlocks = { block("B3", "red") }
	steps(5, 0.25)
	check("read as red again: ORDER UP", tostring(g.activeId ~= misreadId) .. " " .. tostring(g.score > misreadScore), "true true")
	fakeBlocks = {}

	section("16g. Hard: reveal cycle on the TargetBoard (and the cards, via the payload)")
	Config.debugForceMode = "hard"
	fakeBlocks = {}
	g:setState("Idle")
	g:start(tester)
	check("Hard shift starts in show, 5 s left", g.mode .. " " .. g.state .. " " .. g.revealPhase .. " " .. math.ceil(g.revealLeft), "Hard Shift show 5")
	setPattern(g:activeTicket(), { A1 = "red", B2 = { "red", "teal" }, C3 = "yellow" })
	local tblock = board.TargetBoard.Blocks.A1
	check("BlockPool: 12 cells x 2 levels of block parts, level 1 one block higher", #board.TargetBoard.Blocks:GetChildren() == 24
		and math.abs((board.TargetBoard.Blocks.A1_1.Position - tblock.Position).Y - tblock.Size.Y) < 0.001, true)
	local BlockPool = require(pm.BlockPool)
	check("block is 84% of a cell wide and sits on its tile", math.abs(tblock.Size.X - Config.boardCellStuds * BlockPool.BLOCK_FRACTION) < 0.001
		and math.abs((tblock.Position.Y - tblock.Size.Y / 2) - (board.TargetBoard.A1.Position.Y + board.TargetBoard.A1.Size.Y / 2)) < 0.001, true)
	check("block is a rounded-cube MeshPart clone when PatternMatch.BlockMesh exists, else a Part",
		(RS.PatternMatch:FindFirstChild("BlockMesh") ~= nil) == tblock:IsA("MeshPart") and tblock.Material == Enum.Material.SmoothPlastic, true)
	check("target block matches a LiveBoard block (size, material, height above its tile)",
		tblock.Size == board.LiveBoard.Blocks.A1.Size and tblock.Material == board.LiveBoard.Blocks.A1.Material
		and math.abs((tblock.Position.Y - board.TargetBoard.A1.Position.Y) - (board.LiveBoard.Blocks.A1.Position.Y - board.LiveBoard.A1.Position.Y)) < 0.001, true)
	local b2lo, b2hi = board.TargetBoard.Blocks.B2, board.TargetBoard.Blocks.B2_1
	check("show: colors and outlines, B2 red under teal", tblock.Color == Config.colors.red and tblock.TargetOutline.Visible
		and b2lo.Color == Config.colors.red and b2hi.Color == Config.colors.teal and b2hi.TargetOutline.Visible, true)
	check("show: non-target cell has no block", board.TargetBoard.Blocks.A4.Transparency == 1 and not board.TargetBoard.Blocks.A4.TargetOutline.Visible, true)
	steps(19, 0.25) -- 4.75 s
	check("4.75 s: still show, 1 s left on HUD", g.revealPhase .. " " .. sent[#sent].revealTimeLeft, "show 1")
	g:step(0.25) -- 5.0 s
	check("5.0 s: hide; the payload tells the cards to gray out", g.revealPhase .. " " .. sent[#sent].revealPhase, "hide hide")
	check("hide: every level gray, outlines stay", tblock.Color == TargetBoard.HIDDEN and b2lo.Color == TargetBoard.HIDDEN
		and b2hi.Color == TargetBoard.HIDDEN and b2hi.TargetOutline.Visible, true)
	check("hide: the cards keep their layout (cells still on the payload)", sent[#sent].tickets[1].cells.B2[2], "teal")
	local woodTiles = 0
	for _, c in ipairs(cells) do
		if board.TargetBoard[c].Color == cab.TargetBoard[c].Color then woodTiles += 1 end
	end
	check("all 12 TargetBoard squares keep their chessboard wood colors", woodTiles, 12)
	steps(20, 0.25) -- 10.0 s
	check("10.0 s: show again", g.revealPhase, "show")
	steps(20, 0.25) -- 15.0 s, back in hide
	fakeBlocks = blocksFor({ A1 = "red", B2 = { "red", "teal" }, C3 = "yellow" })
	steps(4, 0.25)
	check("completed during hide", sent[#sent].completedCount, 1)
	Config.debugForceMode = nil

	section("17. Easy mode, LiveBoard problem highlight on the specific block")
	startEasy()
	check("debugForceMode=nil: auto-picked Easy, shift running", g.mode .. " " .. g.state, "Easy Shift")
	check("easy: no reveal phase, no outline", tostring(g.revealPhase) .. " " .. tostring(board.TargetBoard.Blocks.A1.TargetOutline.Visible), "nil false")
	setPattern(g:activeTicket(), { A1 = "red", B2 = "teal" })
	fakeBlocks = blocksFor({ A1 = "red", B2 = "teal" })
	table.insert(fakeBlocks, block("C1", "red"))                       -- extra
	table.insert(fakeBlocks, block("C2", "red"))                       -- double...
	table.insert(fakeBlocks, block("C2", "teal", { x = select(1, at(3, 2)) + 1 }))
	table.insert(fakeBlocks, block("A1", "purple", { level = 1 }))     -- stack on a correct target cell
	g:step(0.25)
	local function litBlocks()
		local lit = {}
		for _, p in ipairs(board.LiveBoard.Blocks:GetChildren()) do
			if p.ProblemHighlight.Visible then table.insert(lit, p.Name) end
		end
		table.sort(lit)
		return lit
	end
	check("extra + double (level 0) + stacked block (level 1) outlined, not the correct block under the stack", litBlocks(), { "A1_1", "C1", "C2" })
	fakeBlocks = {}
	g:step(0.25)
	check("problems removed -> highlights cleared", litBlocks(), {})

	section("22. mode select: only the starter picks, only during ModeSelect, only once")
	local alice, bob = { Name = "Alice", UserId = 101 }, { Name = "Bob", UserId = 202 }
	Config.debugForceMode = nil
	fakeBlocks = {}
	g:setState("Idle")
	check("Alice starts a game", g:start(alice), true)
	check("state | chooser | HUD message", g.state .. " | " .. sent[#sent].chooser .. " | " .. sent[#sent].message,
		"ModeSelect | Alice | Alice is choosing a mode")
	check("Bob can't pick", g:pick(bob, "hard"), false)
	check("an unknown choice is rejected", g:pick(alice, "medium"), false)
	check("still choosing, no mode yet", g.state .. " " .. tostring(g.mode), "ModeSelect nil")
	check("ticket picks and cycling are ignored outside the shift", tostring(g:selectTicket(alice, 1)) .. " " .. tostring(g:cycleTicket(alice, 1)), "false false")
	check("Alice picks hard", g:pick(alice, "hard"), true)
	check("payload: confirming, mode, message", tostring(sent[#sent].confirming) .. " " .. sent[#sent].mode .. " | " .. sent[#sent].message,
		"true Hard | HARD MODE")
	check("a second pick is rejected", g:pick(alice, "easy"), false)
	steps(5, 0.25) -- 1.25 s of the 1.5 s confirmation
	check("confirmation still showing at 1.25 s", g.state, "ModeSelect")
	g:step(0.25)
	check("then the shift starts in Hard", g.state .. " " .. g.mode, "Shift Hard")
	check("a pick during the shift is rejected", g:pick(alice, "easy"), false)
	g:setState("Idle")
	g:start(alice)
	steps(59, 0.25) -- 14.75 s
	check("14.75 s: no pick yet", g.state .. " " .. tostring(g.mode), "ModeSelect nil")
	g:step(0.25)
	check("15 s: auto-picks Easy and confirms", g.mode .. " " .. tostring(sent[#sent].confirming) .. " " .. sent[#sent].message, "Easy true EASY MODE")
	Config.debugForceMode = "easy"
	g:setState("Idle")
	g:start(alice)
	check("debugForceMode=easy skips the screen", g.state .. " " .. g.mode, "Shift Easy")
	Config.debugForceMode = nil
	g:setState("Idle")

	section("23. only the TargetBoard spins; the LiveBoard and the arm twin stay fixed")
	local BoardSpinner = require(pm.BoardSpinner)
	g.liveBoard:render({ block("A1", "red"), block("B3", "teal"), block("C4", "yellow") })
	local function offCells(boardModel)
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

	local liveBase0 = board.LiveBoard.Base.CFrame
	local twinBase0 = board.LiveBoard:FindFirstChild("ArmTwin") and board.LiveBoard.ArmTwin.Base.CFrame
	local liveSpinner = BoardSpinner.new(board.LiveBoard)
	liveSpinner:request()
	liveSpinner:request()
	task.wait(0.6)
	check("LiveBoard: spin requests are ignored (not busy, Base exactly where it was)",
		not liveSpinner:busy() and board.LiveBoard.Base.CFrame == liveBase0, true)
	if twinBase0 then
		check("LiveBoard: the arm twin stays fixed", board.LiveBoard.ArmTwin.Base.CFrame == twinBase0, true)
	end
	check("LiveBoard: A1 / B3 / C4 blocks still on their cells", offCells(board.LiveBoard), 0)
	liveSpinner:destroy()

	g.targetBoard:show(towers({ A1 = "red", B2 = { "red", "teal" }, C3 = "teal" }), false, false)
	local targetSpinner = BoardSpinner.new(board.TargetBoard)
	local tlook0, ta1Start = board.TargetBoard.Base.CFrame.LookVector, board.TargetBoard.A1.Position
	targetSpinner:request()
	local took = waitIdle(targetSpinner, 3)
	check("TargetBoard: one request spins it 90 degrees in about SPIN_SECONDS", math.abs(board.TargetBoard.Base.CFrame.LookVector:Dot(tlook0)) < 0.001
		and took >= BoardSpinner.SPIN_SECONDS - 0.05, true)
	check("1 spin: tiles on Grid.worldPositionOf, block parts (both levels) on their tiles (cells off)", offCells(board.TargetBoard), 0)
	check("1 spin: A1 / B2 tower / C3 target blocks still shown, A2 still empty",
		board.TargetBoard.Blocks.A1.Color == Config.colors.red and board.TargetBoard.Blocks.B2_1.Color == Config.colors.teal
		and board.TargetBoard.Blocks.C3.Color == Config.colors.teal and board.TargetBoard.Blocks.A1.Transparency == 0
		and board.TargetBoard.Blocks.A2.Transparency == 1, true)
	check("1 spin: the board still reads right from its own row C side", boardView(board.TargetBoard), VIEW_OK)
	check("the spin left the LiveBoard alone", board.LiveBoard.Base.CFrame == liveBase0, true)
	targetSpinner:request()
	targetSpinner:request()
	targetSpinner:request()
	waitIdle(targetSpinner, 4)
	check("3 more queued spins run one after another: back to the start", board.TargetBoard.Base.CFrame.LookVector:Dot(tlook0) > 0.9999
		and (board.TargetBoard.A1.Position - ta1Start).Magnitude < 0.001, true)
	check("after 4 spins: cells off", offCells(board.TargetBoard), 0)
	targetSpinner:destroy()
	board:Destroy()
end

section("24. arm twin forward kinematics (ArmTwin.Rig / Driver; all-zero pose = horizontal reach forward)")
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
	check("scale: studs per cm = boardCellStuds / cellSizeMm * 10", math.abs(Rig.studsPerCm() - Config.boardCellStuds / Config.cellSizeMm * 10) < 1e-9, true)
	local chain = Rig.chainPoints({}, true)
	check("chainPoints: 6 points base to tip, the last is Rig.forward's tip", #chain .. " " .. tostring((chain[6] - Rig.forward({}, true).Position).Magnitude < 1e-6)
		.. " " .. tostring((chain[2] - Rig.jointsCm().shoulder_lift).Magnitude < 1e-6), "6 true true")

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

	section("25. arm twin rest pose (Config.twinRestPose) when there is no arm data")
	local rest = Config.twinRestPose
	check("withRest fills missing joints from the rest pose", Driver.withRest({ shoulder_pan = 30 }).shoulder_lift == rest.shoulder_lift
		and Driver.withRest({ shoulder_pan = 30 }).shoulder_pan == 30 and Driver.withRest(nil).elbow_flex == rest.elbow_flex, true)
	check("hasData: nil / {} / {foo=1} false, {gripper=0} true", tostring(Driver.hasData(nil)) .. tostring(Driver.hasData({}))
		.. tostring(Driver.hasData({ foo = 1 })) .. tostring(Driver.hasData({ gripper = 0 })), "falsefalsefalsetrue")
	local full = { shoulder_pan = 12, shoulder_lift = 40, elbow_flex = -30, wrist_flex = 10, wrist_roll = 5, gripper = 70 }
	local same = true
	local plain = Driver.rigAngles(full)
	for name, v in pairs(Driver.rigAngles(Driver.withRest(full))) do
		if math.abs(v - plain[name]) > 1e-9 then same = false end
	end
	check("a full sample drives the twin exactly as before (rest fill changes nothing)", same, true)
	-- Posed joint positions (cm, model frame), walking the same chain as Rig.forward.
	local restAngles = Driver.rigAngles(rest)
	local p = Rig.jointsCm()
	local cf, prev, highest = CFrame.new(), Vector3.zero, 0
	for _, name in ipairs(Rig.CHAIN) do
		cf = cf * CFrame.new(p[name] - prev)
		highest = math.max(highest, cf.Position.Y)
		cf = cf * CFrame.fromAxisAngle(Rig.AXES[name], restAngles[name] or 0)
		prev = p[name]
	end
	local restTip = Rig.forward(restAngles, true).Position
	table.insert(lines, string.format("     (rest pose: tip (%.1f, %.1f, %.1f) cm, highest joint %.1f cm above the base)", restTip.X, restTip.Y, restTip.Z, highest))
	check("rest pose is folded: tip above the apron and within 12 cm of the base center", restTip.Y > 0
		and Vector2.new(restTip.X, restTip.Z).Magnitude < 12, true)
	check("rest pose joints stay under 25 cm (about 17.5 studs above the base: below the ceiling)", highest < 25, true)
	local poseEvent = Instance.new("BindableEvent")
	local fakeRemote = { OnClientEvent = poseEvent.Event }
	local twinModel = twinTemplate:Clone()
	local handle = Driver.attach(twinModel, fakeRemote)
	local startedResting = handle.resting()
	poseEvent:Fire(full)
	task.wait(0.1)
	local tracking = not handle.resting()
	task.wait(Driver.STALE_SECONDS + 0.3)
	check("attach: starts resting, a sample takes over, stale data goes back to rest",
		tostring(startedResting) .. " " .. tostring(tracking) .. " " .. tostring(handle.resting()), "true true true")
	poseEvent:Fire(full)
	task.wait(0.1)
	poseEvent:Fire({})
	task.wait(0.1)
	check("an empty sample rests right away", handle.resting(), true)
	handle.destroy()
	twinModel:Destroy()
else
	check("ReplicatedStorage.ArmTwin exists", false, true)
end

section("26. attract mode: the Idle demo loop (off in the arcade; the code is kept)")
local attractWas = Config.attractEnabled
Config.attractEnabled = true
if cab then
	local AttractModule = require(pm.Attract)
	local board = cab:Clone()
	local storeBlocks = { block("A1", "red") } -- what the (fake) StateStore holds
	local snapshot
	local function storeText()
		local parts = {}
		for _, b in ipairs(storeBlocks) do
			table.insert(parts, b.id .. ":" .. b.color .. ":" .. b.x .. ":" .. b.y .. ":" .. b.level)
		end
		return #storeBlocks .. "|" .. table.concat(parts, ",")
	end
	snapshot = storeText()
	local storeWrites = 0
	local storeReads = 0
	local store = setmetatable({
		get = function() storeReads += 1; return { blocks = storeBlocks } end,
		update = function() storeWrites += 1 end,
	}, { __newindex = function(t, k, v) storeWrites += 1; rawset(t, k, v) end })
	local sent = {}
	local g = Game.new({ cabinet = board, store = store,
		ui = { FireAllClients = function(_, p) table.insert(sent, p) end, FireClient = function() end }, manualAttract = true })
	local A = g.attract
	local livePool, targetPool = g.liveBoard.blocks, g.targetBoard.blocks
	local function shown(pool)
		local n = 0
		for _, tower in pairs(pool.parts) do
			for _, part in pairs(tower) do
				if part.Transparency == 0 then n += 1 end
			end
		end
		return n
	end
	local function atRest(pool)
		for cell, tower in pairs(pool.parts) do
			for level, part in pairs(tower) do
				local rest = require(pm.BlockPool).restOn(pool.tiles[cell], level, pool.width)
				if (part.Position - rest.Position).Magnitude > 0.001 or math.abs(part.Size.X - pool.width) > 0.001 then return false end
			end
		end
		return true
	end
	-- Runs the demo until its pattern index changes (or a time limit), in 0.05 s steps.
	local function finishPattern()
		local from, elapsed = A.index, 0
		repeat A:advance(0.05); elapsed += 0.05 until A.index ~= from or elapsed > 30
	end

	g:setState("Idle")
	check("Idle starts the demo, with the sign above the boards", tostring(A.running) .. " " .. tostring(board.AttractSign.Sign.Enabled)
		.. " | " .. board.AttractSign.Sign.Title.Text .. " | " .. board.AttractSign.Sign.Subtitle.Text,
		"true true | Match the target board! | Press Play to start")
	local n, tallest = Target.count(A.target)
	check("TargetBoard shows a 2-4 block demo pattern, the LiveBoard starts empty", n >= 2 and n <= 4 and shown(targetPool) == n
		and shown(livePool) == 0, true)
	g:step(0.2)
	check("Game:step leaves the LiveBoard to the demo (the store's A1 block is not drawn)", shown(livePool), 0)
	local order = AttractModule.placements(A.target)
	local stackedFirst = false
	local seenTop = false
	for _, step in ipairs(order) do
		if step.level > 0 then seenTop = true elseif seenTop then stackedFirst = true end
	end
	check("placement order: every bottom block before any stacked block", stackedFirst, false)
	A:advance(AttractModule.SHOW_SECONDS + 0.01)
	A:advance(0.01)
	local first = order[1]
	local part = livePool:part(first.cell, first.level)
	local rest = require(pm.BlockPool).restOn(livePool.tiles[first.cell], first.level, livePool.width)
	check("first block placed in its color, dropping in from above", shown(livePool) .. " " .. tostring(part.Color == Config.colors[first.color])
		.. " " .. tostring(part.Position.Y - rest.Position.Y > 1), "1 true true")
	A:advance(AttractModule.DROP_SECONDS)
	check("...and it lands on its rest place", (part.Position - rest.Position).Magnitude < 0.001, true)
	local counts = { shown(livePool) }
	for _ = 2, n do
		A:advance(Config.attractPlaceInterval - AttractModule.DROP_SECONDS)
		A:advance(AttractModule.DROP_SECONDS)
		table.insert(counts, shown(livePool))
	end
	check("one block per " .. Config.attractPlaceInterval .. " s until the pattern is built", table.concat(counts, ","),
		table.concat((function() local t = {} for i = 1, n do t[i] = i end return t end)(), ","))
	check("the LiveBoard now matches the target", Target.compare(A.target, (function()
		local lg = {}
		for cell, tower in pairs(livePool.parts) do
			for level, p in pairs(tower) do
				if p.Transparency == 0 then
					lg[cell] = lg[cell] or {}
					for name, color in pairs(Config.colors) do
						if color == p.Color then lg[cell][level] = { name } end
					end
				end
			end
		end
		return lg
	end)(), {}).clear, true)
	A:advance(Config.attractPlaceInterval)
	check("matched: a short hold before COMPLETE!", A.phase .. " " .. A.completions, "hold 0")
	A:advance(AttractModule.HOLD_SECONDS + 0.01)
	local C = g.celebrate
	local sparkling = 0
	for _, emitter in ipairs(C.emitters) do if emitter.Enabled then sparkling += 1 end end
	check("COMPLETE!: the shared celebration text pops in (starts small), the sign steps aside",
		C.label.Text .. " " .. tostring(C.gui.Enabled) .. " " .. tostring(C.scale.Scale < 1) .. " " .. tostring(board.AttractSign.Sign.Enabled) .. " " .. A.completions,
		"COMPLETE! true true false 1")
	local flashed = 0
	for _, tile in ipairs(C.tiles) do if tile.part.Color == C.FLASH_COLOR then flashed += 1 end end
	check("sparkle burst on both boards, every cell of both boards flashed white", sparkling .. " " .. flashed .. "/" .. #C.tiles, "2 24/24")
	local emitter = C.emitters[1]
	check("a bigger, longer burst: rate 450, size up to 1.8, particles up to 1.6 s", string.format("%d %.1f %.1f", emitter.Rate,
		emitter.Size.Keypoints[1].Value, emitter.Lifetime.Max), "450 1.8 1.6")
	A:advance(AttractModule.POP_SECONDS / 3)
	check("blocks swell as they pop", livePool:part(first.cell, first.level).Size.X > livePool.width, true)
	A:advance(AttractModule.POP_SECONDS)
	check("blocks popped away on both boards, back to full size", shown(livePool) .. " " .. shown(targetPool) .. " "
		.. tostring(atRest(livePool) and atRest(targetPool)), "0 0 true")
	task.wait(C.SECONDS + 0.2) -- the celebration runs on real time
	local restored = 0
	for _, tile in ipairs(C.tiles) do if tile.part.Color == tile.color then restored += 1 end end
	check("after ~1.5 s: sparkles off, text gone, every cell back to its wood color", tostring(C.emitters[1].Enabled or C.emitters[2].Enabled)
		.. " " .. tostring(C.gui.Enabled) .. " " .. restored .. "/" .. #C.tiles, "false false 24/24")
	A:advance(AttractModule.GAP_SECONDS + 0.01)
	check("after the gap: the next pattern, sign back to the invitation", A.index .. " " .. tostring(shown(targetPool) > 0)
		.. " " .. board.AttractSign.Sign.Title.Text, "2 true Match the target board!")
	local firstSet = A.set
	for _ = A.index, Config.attractPatterns do finishPattern() end
	check("after " .. Config.attractPatterns .. " patterns: a fresh set, from its first pattern", tostring(A.set ~= firstSet) .. " " .. A.index
		.. " " .. A.completions, "true 1 " .. Config.attractPatterns)
	Config.uniqueColorsPerTicket = true
	check("uniqueColorsPerTicket on: attract patterns never repeat a color, towers included (40 fresh sets)", (function()
		for _ = 1, 40 do
			for _, t in ipairs(A:newSet()) do
				local seen = {}
				for _, tower in pairs(t) do
					for _, color in ipairs(tower) do
						if seen[color] then return false end
						seen[color] = true
					end
				end
			end
		end
		return true
	end)(), true)
	Config.uniqueColorsPerTicket = false
	local setsWithStack = 0
	for _ = 1, 40 do
		for _, t in ipairs(A:newSet()) do
			local _, high = Target.count(t)
			if high > 1 then setsWithStack += 1 break end
		end
	end
	check("every demo set has at least one stacked pattern (40 sets)", setsWithStack, 40)

	-- Stop on mode select, mid-placement.
	A:advance(AttractModule.SHOW_SECONDS + 0.01)
	A:advance(0.01)
	A:advance(Config.attractPlaceInterval)
	check("mid-placement before Play", shown(livePool) >= 1 and shown(targetPool) >= 2, true)
	check("the demo never wrote to the StateStore", storeWrites .. " " .. tostring(storeText() == snapshot), "0 true")
	check("...and never read it (no bridge data while the demo runs)", storeReads, 0)
	check("Attract does not require Core.StateStore", string.find(pm.Attract.Source, "require%([^)]*StateStore") == nil, true)
	g.celebrate:burst("COMPLETE!") -- a burst in flight when Play is pressed
	g:start({ Name = "Tester", UserId = 1 })
	check("mode select stops the demo", g.state .. " " .. tostring(A.running), "ModeSelect false")
	local exact = 0
	for _, tile in ipairs(g.celebrate.tiles) do if tile.part.Color == tile.color then exact += 1 end end
	check("...and cuts a celebration short: cells back to wood at once", exact .. "/" .. #g.celebrate.tiles, "24/24")
	check("both boards cleared, every block back at rest, sign and sparkles off", shown(livePool) .. " " .. shown(targetPool) .. " "
		.. tostring(atRest(livePool) and atRest(targetPool)) .. " " .. tostring(board.AttractSign.Sign.Enabled) .. " "
		.. tostring(g.celebrate.emitters[1].Enabled or g.celebrate.emitters[2].Enabled or g.celebrate.gui.Enabled), "0 0 true false false")
	A:advance(5)
	check("no timers left: advancing a stopped demo changes nothing", shown(livePool) .. " " .. shown(targetPool), "0 0")
	g:step(0.2)
	check("the game draws the LiveBoard from the store again (A1 red)", livePool:part("A1", 0).Transparency == 0
		and livePool:part("A1", 0).Color == Config.colors.red, true)
	check("still no StateStore writes", storeWrites .. " " .. tostring(storeText() == snapshot), "0 true")

	-- Back to Idle after Results: the demo starts again.
	g:setState("Results")
	check("Results: no demo", A.running, false)
	g:step(Config.resultsSeconds)
	check("Idle after Results restarts the demo", g.state .. " " .. tostring(A.running) .. " " .. tostring(shown(targetPool) > 0), "Idle true true")
	Config.attractEnabled = false
	g:start({ Name = "Tester", UserId = 1 })
	g:setState("Idle")
	check("attractEnabled = false: Idle without the demo", tostring(A.running) .. " " .. shown(targetPool), "false 0")
	board:Destroy()
end

Config.attractEnabled = attractWas

section("27. bridge grid: hello.space.grid drives the cell lookup (mock's hello; then a moved sheet)")
do
	local G = require(RS.PatternMatch.Grid) -- the module Core.StateStore and ArmTwin.Stick use
	local mockGrid = { origin_mm = { 25.4, 22.225 }, cell_mm = 57.15, rows = { "A", "B", "C" }, cols = { 1, 2, 3, 4 } }
	-- bridge/producers/mock.py's cell(): letter is the row (A nearest the arm), number the column
	local function mockCell(grid, name)
		local row = string.byte(name) - 64
		local col = tonumber(string.sub(name, 2))
		return grid.origin_mm[1] + (col - 0.5) * grid.cell_mm, grid.origin_mm[2] + (row - 0.5) * grid.cell_mm
	end
	local function allNamed(grid)
		local bad = {}
		for _, name in ipairs(G.allCells()) do
			local got = G.cellOf(mockCell(grid, name))
			if got ~= name then table.insert(bad, name .. "->" .. tostring(got)) end
		end
		return #bad == 0 and "all 12" or table.concat(bad, " ")
	end
	check("mock hello grid: no warning", G.setGeometry(mockGrid), nil)
	check("mock hello grid: every mock cell center reads as its own name", allNamed(mockGrid), "all 12")
	local moved = { origin_mm = { 40, 30 }, cell_mm = 50, rows = { "A", "B", "C" }, cols = { 1, 2, 3, 4 } }
	G.setGeometry(moved)
	check("moved sheet (origin 40,30, cell 50): geometry follows the hello", G.geometry().originX .. " " .. G.geometry().cell, "40 50")
	check("moved sheet: every cell center reads as its own name", allNamed(moved), "all 12")
	check("moved sheet: (65, 55) is A1, (115, 55) is A2", G.cellOf(65, 55) .. " " .. G.cellOf(115, 55), "A1 A2")
	local warning = G.setGeometry({ origin_mm = { 22.225, 48.26 }, cell_mm = 57.15, rows = { "A", "B", "C" }, cols = { 1, 2, 3 } })
	check("a 3x3 hello keeps the boards' 3x4 (with a warning)", tostring(warning ~= nil) .. " " .. #G.allCells() .. " " .. G.geometry().originY, "true 12 48.26")
	G.setGeometry(nil)
	check("setGeometry(nil): Config's grid again", G.geometry().originX == Config.gridOriginMm.X and G.geometry().cell == Config.cellSizeMm, true)

	-- Orientation, re-run against the mock's grid: a sheet point lands on the LiveBoard tile of the cell it
	-- reads as, so A1 is far-left from the row C side and C4 near-right (the board view test in 14).
	local cabModel = cab
	if cabModel then
		local lb = cabModel.LiveBoard
		G.setGeometry(mockGrid)
		local off = {}
		for _, name in ipairs(G.allCells()) do
			local x, y = mockCell(mockGrid, name)
			local w = G.sheetToWorld(x, y, 0, lb)
			local tile = lb[name]
			local d = Vector3.new(w.X - tile.Position.X, w.Y - (tile.Position.Y + tile.Size.Y / 2), w.Z - tile.Position.Z)
			if d.Magnitude > 0.01 then table.insert(off, name) end
		end
		check("mock grid: each cell center (z 0) lands on its LiveBoard tile's top", #off == 0 and "all 12" or table.concat(off, " "), "all 12")
		local a1x, a1y = mockCell(mockGrid, "A1")
		check("z scales like x and y: 48 mm up is 48 * boardCellStuds / 57.15 studs",
			math.abs(G.sheetToWorld(a1x, a1y, 48, lb).Y - G.sheetToWorld(a1x, a1y, 0, lb).Y - 48 * Config.boardCellStuds / 57.15) < 1e-6, true)
		local GConfig = require(RS.PatternMatch.Config) -- the Config that G reads
		GConfig.flipX = true
		local flipped = G.sheetToWorld(a1x, a1y, 0, lb)
		GConfig.flipX = false
		check("flipX: the A1 point is drawn over A4, as cellOf reads it", (Vector3.new(flipped.X, 0, flipped.Z) - Vector3.new(lb.A4.Position.X, 0, lb.A4.Position.Z)).Magnitude < 0.01, true)
		G.setGeometry(nil)
	end
end

section("28. Core.StateStore adapter (edit mode: no bridge, nothing connects)")
do
	local core = RS.Core:Clone()
	local Store = require(core.StateStore)
	check("source / status before any hello", Store.source() .. " " .. Store.status(), "pending offline")
	check("sendEvent without the bridge: Roblox side only", select(2, Store.sendEvent("earthquake", 0.5, 4)), "no robot bridge (pending)")
	local function ls(...) return Store.linkStatus(...) end
	check("badge: mock -> MOCK; teleop, follower, auto, a new name or none -> ROBOT LIVE",
		table.concat({ ls("mock", 0.1, 0.1, 0.03), ls("teleop", 0.1, 0.1, 0.03), ls("follower", 0.1, 0.1, 0.03),
			ls("auto", 0.1, 0.1, 0.03), ls("crane2000", 0.1, 0.1, 0.03), ls(nil, 0.1, 0.1, 0.03) }, " "),
		"mock live live live live live")
	check("null ages: blocks_age or arm_age nil -> offline (both, and the first frame not in yet)",
		table.concat({ ls("teleop", 0.1, nil, 0.03), ls("teleop", 0.1, 0.1, nil), ls("mock", 0.1, nil, nil), ls("mock", nil, 0.1, 0.03) }, " "),
		"offline offline offline offline")
	check("stale: no frame for 1.5 s, or blocks_age 1.5 -> offline; ages as strings still read",
		table.concat({ ls("mock", 1.5, 0.1, 0.03), ls("mock", 0.1, 1.5, 0.03), ls("mock", 0.1, "0.1", "0.03") }, " "),
		"offline offline mock")
	check("a frame with every part null converts without an error", (function()
		local ok, st = pcall(Store.fromFrame, { t = "state", seq = 1, ts = 0, arm = nil, arm_age = nil, blocks = nil, blocks_age = nil })
		return tostring(ok) .. " " .. tostring(ok and st.arm) .. " " .. tostring(ok and #st.blocks)
	end)(), "true nil 0")
	local frame = { t = "state", seq = 5, ts = 1, arm_age = 0.02, blocks_age = 0.1,
		arm = { joints = {}, points = { { name = "shoulder_pan", x = 1, y = 2, z = 3 }, { name = "tip", x = 4, y = 5, z = 6 } } },
		blocks = {
			{ id = 1, color = "light blue", x = 50, y = 50, z = 0, yaw = 0, level = 0, held = false, visible = true, age = 0 },
			{ id = 2, color = "grey", x = 60, y = 60, z = 90, yaw = 0, level = 0, held = true, visible = true, age = 0 },
			{ id = 3, color = "red", x = 70, y = 70, z = 0, yaw = 0, level = 1, held = false, visible = true, age = 0 },
		} }
	local s1 = Store.fromFrame(frame)
	check("fromFrame: light blue -> skyblue, held grey left alone, red kept", s1.blocks[1].color .. " " .. s1.blocks[2].color .. " " .. s1.blocks[3].color, "skyblue grey red")
	check("fromFrame: arm kept with its points, blocks_age carried", #s1.arm.points .. " " .. s1.blocks_age, "2 0.1")
	check("fromFrame: an arm with no points is no arm data", Store.fromFrame({ blocks = {}, arm = { joints = {}, points = {} } }).arm, nil)
	check("fromFrame does not touch the frame it was given", frame.blocks[1].color, "light blue")
	local SC = require(RS.PatternMatch.Config) -- the Config that Store reads
	check("perceptionColors: the six kit names map onto Config.colors, one each", (function()
		local out, used = {}, {}
		for _, c in ipairs({ "red", "orange", "yellow", "teal", "purple", "light blue" }) do
			local ours = Store.colorName(c)
			if SC.colors[ours] == nil or used[ours] then return "bad " .. c end
			used[ours] = true
			table.insert(out, ours)
		end
		local n = 0
		for _ in pairs(SC.perceptionColors) do n += 1 end
		return table.concat(out, ",") .. " (" .. n .. " entries)"
	end)(), "red,orange,yellow,teal,purple,skyblue (6 entries)")
	check("any other name is kept as sent (a misread)", (function()
		local out = {}
		for _, c in ipairs({ "green", "blue", "pink", "white", "black", "grey", "light_blue" }) do table.insert(out, Store.colorName(c)) end
		return table.concat(out, ",")
	end)(), "green,blue,pink,white,black,grey,light_blue")
	local misreadFrame = Store.fromFrame({ blocks = {
		{ id = 1, color = "green", x = 50, y = 50, z = 0, level = 0, held = false, visible = true, age = 0 },
		{ id = 2, color = "grey", x = 60, y = 60, z = 0, level = 0, held = false, visible = true, age = 0 },
		{ id = 3, color = "grey", x = 60, y = 60, z = 90, level = 0, held = true, visible = true, age = 0 } } })
	check("fromFrame: non-held green / grey stay as misreads; a held grey is left alone", misreadFrame.blocks[1].color .. " "
		.. misreadFrame.blocks[2].color .. " " .. misreadFrame.blocks[3].color, "green grey grey")
	local fa = Store.fakeArm(Config.twinRestPose)
	check("fake arm: 6 sheet-mm points named like the protocol, base before row A", fa ~= nil and #fa.points == 6 and fa.points[1].name == "shoulder_pan"
		and fa.points[6].name == "tip" and fa.points[1].y < Config.gridOriginMm.Y, true)
	core:Destroy()
end

section("29. stick-figure arm twin (ArmTwin.Stick) from arm.points")
local cabModel = cab
if RS:FindFirstChild("ArmTwin") and RS.ArmTwin:FindFirstChild("Stick") and cabModel then
	local twinCopy = RS.ArmTwin:Clone()
	local StickM = require(twinCopy.Stick)
	local RigM = require(twinCopy.Rig)
	local DriverM = require(twinCopy.Driver)
	local lb = cabModel.LiveBoard
	local a1x, a1y = O.X + S / 2, O.Y + S / 2
	local pose = StickM.payload({ { name = "shoulder_pan", x = 140, y = -100, z = 68 }, { name = "tip", x = a1x, y = a1y, z = 0 } }, lb)
	check("payload: the tip at A1's center on the paper lands on LiveBoard A1's top", (pose.points[2] - Vector3.new(lb.A1.Position.X, lb.A1.Position.Y + lb.A1.Size.Y / 2, lb.A1.Position.Z)).Magnitude < 0.01, true)
	check("payload: foot is the first point dropped to the paper; scale is the board's", math.abs(pose.foot.X - pose.points[1].X) < 1e-6
		and math.abs(pose.foot.Y - (lb.A1.Position.Y + lb.A1.Size.Y / 2)) < 0.01 and math.abs(pose.scale - Config.boardCellStuds / Config.cellSizeMm) < 1e-9, true)
	check("payload: no points -> nil (the twin rests)", StickM.payload({}, lb), nil)
	local twinModel = lb.ArmTwin:Clone()
	local rest = StickM.restPayload(twinModel)
	local restTip = twinModel:GetPivot():PointToWorldSpace(RigM.forward(DriverM.rigAngles(DriverM.restPose())).Position)
	check("rest pose: the rig's folded pose at the twin's pivot, tip where the rig's FK puts it", #rest.points .. " " .. tostring((rest.points[6] - restTip).Magnitude < 1e-4), "6 true")
	local poseEvent = Instance.new("BindableEvent")
	local folder = Instance.new("Folder")
	local handle = StickM.attach(twinModel, { OnClientEvent = poseEvent.Event }, folder)
	local hidden = true
	for _, d in ipairs(twinModel:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency ~= 1 then hidden = false end
	end
	check("attach: the Motor6D rig is hidden; the stick has a base, 5 links and 6 balls", tostring(hidden) .. " " .. #handle.model:GetChildren(), "true 12")
	local started = handle.resting()
	local arm6 = {}
	for i, n in ipairs(RigM.POINT_NAMES) do arm6[i] = { name = n, x = 100 + i * 10, y = 40, z = 60 } end
	poseEvent:Fire(StickM.payload(arm6, lb))
	task.wait(0.6)
	local tipNow = handle.current().points[6]
	local tipWant = StickM.payload(arm6, lb).points[6]
	check("attach: starts resting, eases onto a sample", tostring(started) .. " " .. tostring(handle.resting()) .. " "
		.. tostring((tipNow - tipWant).Magnitude < 0.1), "true false true")
	task.wait(StickM.STALE_SECONDS + 0.2)
	check("stale samples: back to resting", handle.resting(), true)
	handle.destroy()
	twinModel:Destroy()
	folder:Destroy()
	twinCopy:Destroy()
else
	check("ReplicatedStorage.ArmTwin.Stick and the cabinet exist", false, true)
end

section("30. roles (Core.Roles): assignment with fake players, swap, the remote guard")
do
	local RolesM = require(RS.Core.Roles:Clone())
	local function fake(name)
		local attrs = {}
		return { Name = name, UserId = #name, SetAttribute = function(_, k, v) attrs[k] = v end,
			GetAttribute = function(_, k) return attrs[k] end }
	end
	local a = RolesM.Assigner.new()
	local p1, p2, p3, p4 = fake("Ann"), fake("Bo"), fake("Cy"), fake("Di")
	check("join order: player, robot, spectator, spectator", table.concat({ a:join(p1), a:join(p2), a:join(p3), a:join(p4) }, " "),
		"player robot spectator spectator")
	check("the Role attribute is set on each Player", table.concat({ p1:GetAttribute("Role"), p2:GetAttribute("Role"),
		p3:GetAttribute("Role"), RolesM.of(p4) }, " "), "player robot spectator spectator")
	a:leave(p1)
	check("the player leaves: the role is empty, spectators keep theirs", tostring(a:holder("player")) .. " " .. a:roleOf(p3), "nil spectator")
	local p5 = fake("Ed")
	check("the next client to join fills it", a:join(p5) .. " " .. tostring(a:holder("player") == p5), "player true")
	a:leave(p2)
	local p6 = fake("Flo")
	check("the robot leaves and rejoins: robot again", a:join(p6) .. " / " .. a:join(p2), "robot / spectator")
	local changed = a:swap()
	check("swap: the player and robot trade, attributes follow, spectators untouched",
		#changed .. " " .. RolesM.of(p5) .. " " .. RolesM.of(p6) .. " " .. RolesM.of(p3), "2 robot player spectator")
	a:swap()
	check("swap twice: back where it was", RolesM.of(p5) .. " " .. RolesM.of(p6), "player robot")
	local solo = RolesM.Assigner.new()
	local only = fake("Solo")
	solo:join(only)
	check("solo swap (no robot yet): the player becomes the robot, player empty", #solo:swap() .. " " .. RolesM.of(only)
		.. " " .. tostring(solo:holder("player")), "1 robot nil")
	local forced = RolesM.Assigner.new({ forced = "robot" })
	check("debugForceRole robot: the first client is the robot, the second the player",
		forced:join(fake("A")) .. " " .. forced:join(fake("B")) .. " " .. forced:join(fake("C")), "robot player spectator")
	local forcedPlayer = RolesM.Assigner.new({ forced = "player" })
	check("debugForceRole player: same as normal", forcedPlayer:join(fake("A")) .. " " .. forcedPlayer:join(fake("B")), "player robot")

	local calls = {}
	local guarded = RolesM.guard(function(player, value) table.insert(calls, player.Name .. "=" .. tostring(value)); return "ran" end, "TestRemote")
	local robot, spectator, nobody = fake("Rob"), fake("Spec"), fake("New")
	robot:SetAttribute("Role", "robot")
	spectator:SetAttribute("Role", "spectator")
	local player = fake("Pat")
	player:SetAttribute("Role", "player")
	check("guard: the robot's call is dropped", guarded(robot, 1), nil)
	check("guard: a spectator's call is dropped", guarded(spectator, 2), nil)
	check("guard: a client with no role yet is dropped", guarded(nobody, 3), nil)
	check("guard: the player's call runs, arguments intact", tostring(guarded(player, 4)) .. " " .. table.concat(calls, ","), "ran Pat=4")
end

section("31. game registry (Core.GameRegistry): entries, the view each role shows")
do
	local core = RS.Core:Clone()
	local Registry = require(core.GameRegistry)
	local pmEntry = Registry.get("PatternMatch")
	check("Pattern Match is registered (Core.Games.PatternMatch): name, not the lobby (an arcade mode), two view modules",
		pmEntry ~= nil and pmEntry.name .. " " .. tostring(pmEntry.lobby) .. " " .. pmEntry.playerView.Name .. " " .. pmEntry.robotView.Name,
		"Pattern Match false PlayerView RobotView")
	check("no lobby game: in the lobby a player shows no Pattern Match view", tostring(Registry.lobbyEntry()), "nil")
	local views = {}
	for _, m in ipairs({ pmEntry.playerView, pmEntry.robotView, RS.Core.Views.LobbyRobotView }) do
		local v = require(m) -- the real modules: PlayerView finds its templates through script.Parent
		table.insert(views, m.Name .. "=" .. tostring(type(v.enter) == "function" and type(v.exit) == "function"))
	end
	check("every view module has enter() and exit()", table.concat(views, " "), "PlayerView=true RobotView=true LobbyRobotView=true")
	local fakeGame = { id = "Obby", playerView = "obby player", robotView = "obby robot" }
	local lobby = { id = "PM", playerView = "pm player", robotView = "pm robot", lobby = true }
	local function v(role, active) return tostring(Registry.viewFor(role, active, lobby, "lobby robot")) end
	check("robot: lobby view with no game, the active game's robot view in one",
		v("robot", nil) .. " | " .. v("robot", fakeGame) .. " | " .. v("robot", lobby), "lobby robot | obby robot | pm robot")
	check("player and spectator: the lobby game's player view, then the active game's",
		v("player", nil) .. " | " .. v("spectator", nil) .. " | " .. v("player", fakeGame) .. " | " .. v("spectator", fakeGame),
		"pm player | pm player | obby player | obby player")
	check("no role yet: no view", v(nil, fakeGame), "nil")
	check("no lobby game: a player in the lobby shows nothing", tostring(Registry.viewFor("player", nil, nil, "x")), "nil")
	check("register checks its entry", (pcall(Registry.register, { id = "Bad", name = "Bad" })), false)
	core:Destroy()
end

section("32. Pattern Match for the robot role: its own payload, sent per role; the active game")
if cab then
	local board = cab:Clone()
	local function fake(name, role)
		local attrs = { Role = role }
		return { Name = name, UserId = #name, GetAttribute = function(_, k) return attrs[k] end }
	end
	local full, robotSent = {}, {}
	local ui = { FireAllClients = function() error("FireAllClients with roles") end,
		FireClient = function(_, p, payload) table.insert(full, p.Name .. ":" .. tostring(payload.tickets ~= nil)) end }
	local robotUi = { FireClient = function(_, p, payload) table.insert(robotSent, { name = p.Name, payload = payload }) end }
	local players = { fake("Pat", "player"), fake("Rob", "robot"), fake("Spec", "spectator"), fake("New", nil) }
	local active = {}
	local g = Game.new({ cabinet = board, store = { get = function() return { blocks = {} } end, status = function() return "mock" end },
		ui = ui, robotUi = robotUi, players = function() return players end,
		roleOf = function(p) return p:GetAttribute("Role") end, onActive = function(on) table.insert(active, tostring(on)) end,
		rng = Random.new(3), manualAttract = true })
	g:setState("Idle")
	Config.debugForceMode = "easy"
	g:start(players[1])
	table.clear(full)
	table.clear(robotSent)
	g:pushUI()
	check("everyone but the robot gets the full payload; no role yet gets nothing", table.concat(full, " "), "Pat:true Spec:true")
	local rp = robotSent[1] and robotSent[1].payload or {}
	local keys = {}
	for k in pairs(rp) do table.insert(keys, k) end
	table.sort(keys)
	check("the robot gets only state, timer, score and the win target, tickets done, ORDER UP and the link",
		(robotSent[1] and robotSent[1].name or "-") .. " " .. table.concat(keys, ","), "Rob completedCount,robot,score,state,timeLeft,winPoints")
	local ticket = g:activeTicket()
	g:completeTicket(ticket)
	local last = robotSent[#robotSent].payload
	check("an ORDER UP reaches the robot as seq + points only", tostring(last.orderUp and last.orderUp.seq) .. " "
		.. tostring(last.orderUp and last.orderUp.points == ticket.points) .. " " .. tostring(last.orderUp and last.orderUp.id), "1 true nil")
	check("Game.robotPayload drops tickets, target and reveal; no event fields anywhere", (function()
		local p, full = Game.robotPayload(g:payload()), g:payload()
		return tostring(p.tickets) .. tostring(p.activeId) .. tostring(p.revealPhase) .. tostring(full.event) .. tostring(full.vanishedCells)
	end)(), "nilnilnilnilnil")
	g:pushUI(players[2])
	check("pushUI(robot) sends the robot payload, never the full one", tostring(robotSent[#robotSent].name) .. " " .. tostring(robotSent[#robotSent].payload.tickets), "Rob nil")
	g:setState("Results")
	g:setState("Idle")
	check("active game: on from the start, off back in Idle", table.concat(active, ","), "false,true,true,false")
	Config.debugForceMode = nil
	board:Destroy()
end

local viewsFolder = RS.PatternMatch:FindFirstChild("Views")
check("Views.Player templates: PatternHud, PatternModeSelect (ScreenGuis), PatternWorld (CabinetFocus, ArmTwinClient)", (function()
	local t = viewsFolder and viewsFolder:FindFirstChild("Player")
	if not t then return "missing" end
	local w = t:FindFirstChild("PatternWorld")
	return tostring(t:FindFirstChild("PatternHud") and t.PatternHud:IsA("ScreenGui")) .. " "
		.. tostring(t:FindFirstChild("PatternModeSelect") and t.PatternModeSelect:IsA("ScreenGui")) .. " "
		.. tostring(w and w:FindFirstChild("CabinetFocus") ~= nil and w:FindFirstChild("ArmTwinClient") ~= nil)
end)(), "true true true")
check("nothing of Pattern Match left in StarterGui / StarterPlayerScripts (the views own it)",
	tostring(game:GetService("StarterGui"):FindFirstChild("PatternHud")) .. " " .. tostring(game:GetService("StarterGui"):FindFirstChild("PatternModeSelect"))
	.. " " .. tostring(game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("ArmTwinClient"))
	.. " " .. tostring(game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("CabinetFocus")), "nil nil nil nil")
check("Players.CharacterAutoLoads is off (CoreRoles spawns only the player role)", game:GetService("Players").CharacterAutoLoads, false)
check("the robot view's camera shot keeps the whole cabinet behind it", (function()
	local src = viewsFolder and viewsFolder:FindFirstChild("RobotView") and viewsFolder.RobotView.Source or ""
	local fx, fy, fz = string.match(src, "SHOT_FROM = Vector3.new%(([%-%d%.]+), ([%-%d%.]+), ([%-%d%.]+)%)")
	local ax, ay, az = string.match(src, "SHOT_AT = Vector3.new%(([%-%d%.]+), ([%-%d%.]+), ([%-%d%.]+)%)")
	if not (fx and ax) then return "no shot" end
	local from, at = Vector3.new(tonumber(fx), tonumber(fy), tonumber(fz)), Vector3.new(tonumber(ax), tonumber(ay), tonumber(az))
	local look = (at - from).Unit
	-- The shot is in the map's frame; the Map is stored (and played) at Config.mapOffset.
	from, at = from + Config.mapOffset, at + Config.mapOffset
	look = (at - from).Unit
	-- Every corner of the cabinet's bounding box (and 12 studs above it, the celebration text) is behind
	-- the camera: a negative dot with the look direction.
	if not cab then return "no cabinet" end
	local cf, size = cab:GetBoundingBox()
	for _, sx in ipairs({ -0.5, 0.5 }) do
		for _, sy in ipairs({ -0.5, 0.5 }) do
			for _, sz in ipairs({ -0.5, 0.5 }) do
				local corner = cf:PointToWorldSpace(Vector3.new(sx, sy, sz) * size) + Vector3.new(0, sy > 0 and 12 or 0, 0)
				if (corner - from):Dot(look) >= 0 then return "cabinet in front" end
			end
		end
	end
	return "all behind"
end)(), "all behind")

section("33. arcade mode (ServerStorage.Modes.PatternMatch): contract, Start / Finished / Stop, cleanup")
if modeFolder and modeFolder:FindFirstChild("Module") and mapTemplate then
	-- Fresh copies of every module the mode requires by path (the command bar caches requires), then a
	-- fresh copy of the mode itself (the clone keeps its Map next to its Module).
	local stale = {}
	for _, root in ipairs({ RS.PatternMatch, RS.Core, RS.ArmTwin }) do
		for _, m in ipairs(root:GetDescendants()) do
			if m:IsA("ModuleScript") then table.insert(stale, m) end
		end
	end
	for _, m in ipairs(stale) do
		local copy, parent = m:Clone(), m.Parent
		m:Destroy()
		copy.Parent = parent
	end
	local MC = require(RS.PatternMatch.Config)
	local MGame = require(RS.PatternMatch.Game)
	local Registry = require(RS.Core.GameRegistry)
	local modeCopy = modeFolder:Clone()
	local Mode = require(modeCopy.Module)
	local Lighting = game:GetService("Lighting")

	local function lightingSnapshot()
		local parts = {}
		for _, prop in ipairs({ "Ambient", "Brightness", "ClockTime", "ColorShift_Bottom", "ColorShift_Top", "EnvironmentDiffuseScale",
			"EnvironmentSpecularScale", "ExposureCompensation", "FogColor", "FogEnd", "FogStart", "GeographicLatitude",
			"GlobalShadows", "OutdoorAmbient", "ShadowSoftness", "LightingStyle" }) do
			table.insert(parts, prop .. "=" .. tostring(Lighting[prop]))
		end
		for _, c in ipairs(Lighting:GetDescendants()) do
			table.insert(parts, c:GetFullName() .. ":" .. c.ClassName .. ":" .. tostring(c:IsA("PostEffect") and c.Enabled))
		end
		table.sort(parts)
		return table.concat(parts, ";")
	end
	local function workspaceSnapshot()
		local names = {}
		for _, c in ipairs(workspace:GetChildren()) do table.insert(names, c.Name) end
		table.sort(names)
		return table.concat(names, ",") .. " #" .. #workspace:GetDescendants()
	end
	local lightingBefore, workspaceBefore = lightingSnapshot(), workspaceSnapshot()

	check("contract: name, tip, unlock, Finished, Start / Stop, MaxDuration",
		string.format("%s | %s | %s %s %s %s %s", Mode.DisplayName, Mode.Tip, tostring(Mode.WinsToUnlock),
			typeof(Mode.Finished) == "Instance" and Mode.Finished.ClassName or "-", type(Mode.Start), type(Mode.Stop), type(Mode.MaxDuration)),
		"Pattern Match | Call out the pattern, the robot builds it! | 0 BindableEvent function function number")
	check("win target: Config.winPoints = 20", MC.winPoints, 20)
	local mapCf, mapSize = mapTemplate:GetBoundingBox()
	check("Map: a Persistent Model, stored at Config.mapOffset", mapTemplate.ClassName .. " " .. mapTemplate.ModelStreamingMode.Name .. " "
		.. tostring((mapTemplate:GetPivot().Position - MC.mapOffset).Magnitude < 1e-3), "Model Persistent true")
	check("Map: clear of everything in Workspace (the arcade, its scenery, terrain) and of Flood's chamber, with 20 studs to spare",
		(function()
			local hits = workspace:GetPartBoundsInBox(mapCf, mapSize + Vector3.new(40, 40, 40))
			local region = Region3.new(mapCf.Position - mapSize / 2, mapCf.Position + mapSize / 2):ExpandToGrid(4)
			local mats, occ = workspace.Terrain:ReadVoxels(region, 4)
			local terrain = 0
			for x = 1, mats.Size.X do for y = 1, mats.Size.Y do for z = 1, mats.Size.Z do
				if mats[x][y][z] ~= Enum.Material.Air and occ[x][y][z] > 0 then terrain += 1 end
			end end end
			local flood = game:GetService("ServerStorage").Modes:FindFirstChild("Flood")
			local floodClear = true
			if flood then
				for _, p in ipairs(flood:GetDescendants()) do
					if p:IsA("BasePart") then
						local d = (p.Position - mapCf.Position):Abs() - (mapSize + p.Size) / 2
						if d.X < 20 and d.Y < 20 and d.Z < 20 then floodClear = false break end
					end
				end
			end
			return #hits .. " parts, " .. terrain .. " terrain voxels, flood clear " .. tostring(floodClear)
		end)(), "0 parts, 0 terrain voxels, flood clear true")
	check("Map: no scripts and no SpawnLocation inside", (function()
		local n = 0
		for _, d in ipairs(mapTemplate:GetDescendants()) do
			if d:IsA("LuaSourceContainer") or d:IsA("SpawnLocation") then n += 1 end
		end
		return n
	end)(), 0)
	check("attract demo on for the room; the room waits roomIdleSeconds = 90", tostring(MC.attractEnabled) .. " " .. MC.roomIdleSeconds, "true 90")
	check("no event settings left in Config", tostring(MC.events) .. tostring(MC.debugEventEvery) .. tostring(MC.vanishSeconds)
		.. tostring(MC.easy) .. tostring(MC.hard.eventEvery), "nilnilnilnilnil")

	-- MaxDuration: room wait + mode select countdown + confirmation + shift + every bonus second + results, with margin.
	local longest = MC.roomIdleSeconds + MC.modeSelectSeconds + MC.modeConfirmSeconds + MC.shiftSeconds + MC.maxTimeBonus + MC.resultsSeconds
	check("MaxDuration covers room wait + mode select + shift + all time bonuses + results, with margin, and is above the arcade's 180 s",
		tostring(Mode.MaxDuration >= longest + 10) .. " " .. tostring(Mode.MaxDuration > 180) .. " " .. Mode.MaxDuration .. " >= " .. longest,
		"true true " .. Mode.MaxDuration .. " >= " .. longest)

	local function fakePlayer(name, role)
		local attrs = { Role = role }
		return { Name = name, UserId = 1000 + #name, Parent = game, Character = nil,
			GetAttribute = function(_, k) return attrs[k] end, SetAttribute = function(_, k, v) attrs[k] = v end }
	end
	-- (A BindableEvent copies tables, so these fake players arrive as copies: compare names. Real Player
	-- instances arrive as themselves.)
	local fired = {}
	local finishedConn = Mode.Finished.Event:Connect(function(r) table.insert(fired, r) end)
	local function flush() -- signal handlers are deferred
		for _ = 1, 3 do task.wait() end
	end
	local fakeBlocks = {}
	local store = { get = function() return { blocks = fakeBlocks } end, status = function() return "fake" end }
	-- Runs one game from Start to the end of Results with the given final score: `presser` presses Play
	-- in the room after a few seconds.
	local roomCheck
	local function playTo(players, score, presser)
		local s = Mode.Start(players, { store = store, manual = true, rng = Random.new(5) })
		Mode.step(2)
		roomCheck = s.game.state .. " " .. tostring(s.game.attract.running) .. " " .. tostring(s.prompt.Enabled) .. " " .. s.game.message
			.. " | robot: " .. MGame.robotPayload(s.game:payload()).state
		Mode.play(presser)
		roomCheck ..= " | after Play: " .. s.game.state .. " " .. tostring(s.game.attract.running) .. " " .. tostring(s.prompt.Enabled)
		Mode.step(MC.modeSelectSeconds) -- nobody picks: Easy at 0
		Mode.step(MC.modeConfirmSeconds)
		local inShift = s.game.state
		s.game.score = score
		s.game.timeLeft = 0
		Mode.step(MGame.TICK) -- Results
		local results = s.game:payload()
		Mode.step(MC.resultsSeconds) -- Done: Finished
		Mode.step(MGame.TICK)
		Mode.step(MGame.TICK)
		flush()
		return s, inShift, results
	end

	local pat, sam = fakePlayer("Pat", "player"), fakePlayer("Sam", nil)
	local s1, inShift, resultsPayload = playTo({ pat, sam }, 20, pat)
	check("Start: map in Workspace under Config.mapName at the offset, Pattern Match active, room -> Play -> mode select -> shift",
		tostring(s1.map.Parent == workspace and s1.map.Name == MC.mapName) .. " " .. tostring((s1.map:GetPivot().Position - MC.mapOffset).Magnitude < 1e-3)
		.. " " .. tostring(Registry.active()) .. " " .. inShift, "true true PatternMatch Shift")
	check("Start lands in the room: Idle, demo running, Play prompt on; Play stops the demo, hides the prompt, opens mode select",
		roomCheck, "Idle true true Press Play on the cabinet to start! | robot: Idle | after Play: ModeSelect false false")
	check("whoever pressed Play picks the mode", s1.game.chooserName, "Pat")
	check("results screen first: Results state, won = true, win target in the payload",
		resultsPayload.state .. " " .. tostring(resultsPayload.won) .. " " .. tostring(resultsPayload.winPoints), "Results true 20")
	check("score 20: Finished fires once, list form, one entry per player, won = true",
		#fired .. " " .. #(fired[1] or {}) .. " " .. tostring(fired[1] and fired[1][1].player.Name == "Pat" and fired[1][2].player.Name == "Sam")
		.. " " .. tostring(fired[1] and fired[1][1].won) .. " " .. tostring(fired[1] and fired[1][2].won), "1 2 true true true")
	check("game state Done after Finished; steps after it fire nothing more", s1.game.state .. " " .. #fired, "Done 1")
	Mode.Stop()
	flush()
	check("Stop: map gone, Workspace as before, no active game", tostring(s1.map.Parent) .. " " .. tostring(workspaceSnapshot() == workspaceBefore)
		.. " " .. tostring(Registry.active()), "nil true nil")
	check("Stop: every connection disconnected, every thread done, game shut down, spinner stopped", (function()
		local live = 0
		for _, c in ipairs(s1.conns) do if c.Connected then live += 1 end end
		for _, t in ipairs(s1.threads) do if coroutine.status(t) ~= "dead" then live += 1 end end
		return live .. " " .. tostring(s1.game.stopped) .. " " .. tostring(s1.spinner.connection.Connected) .. " " .. #s1.conns
	end)(), "0 true false " .. #s1.conns)
	check("Stop again is harmless; Finished didn't fire again", (pcall(Mode.Stop)) and #fired, 1)

	-- Start -> Stop -> Start works: a second game, a score under the target.
	table.clear(fired)
	local s2, inShift2 = playTo({ pat }, 19, pat)
	check("a second Start after Stop runs a fresh game (new map, mode select -> shift)",
		tostring(s2 ~= s1 and s2.map ~= s1.map and s2.map.Parent == workspace) .. " " .. inShift2, "true Shift")
	check("score 19: Finished once, won = false", #fired .. " " .. tostring(fired[1] and fired[1][1].player.Name == "Pat") .. " " .. tostring(fired[1] and fired[1][1].won),
		"1 true false")
	Mode.Stop()

	-- A player leaves mid-shift: with someone still there the game goes on; when everyone has left it
	-- ends at once and Finished still fires (won = false for those who left).
	table.clear(fired)
	local a, b = fakePlayer("Ana", "player"), fakePlayer("Bo", "spectator")
	local s3 = Mode.Start({ a, b }, { store = store, manual = true, rng = Random.new(6) })
	Mode.play(a)
	Mode.step(MC.modeSelectSeconds)
	Mode.step(MC.modeConfirmSeconds)
	s3.game.score = 25
	a.Parent = nil
	Mode.step(MGame.TICK)
	flush()
	check("one of two leaves mid-shift: the shift goes on, no Finished yet", s3.game.state .. " " .. #fired, "Shift 0")
	b.Parent = nil
	Mode.step(MGame.TICK)
	flush()
	check("the last player leaves: Finished fires at once, list form, everyone won = false",
		#fired .. " " .. #(fired[1] or {}) .. " " .. tostring(fired[1] and fired[1][1].won) .. " " .. tostring(fired[1] and fired[1][2].won),
		"1 2 false false")
	Mode.step(MC.resultsSeconds)
	flush()
	check("...and only once", #fired, 1)
	Mode.Stop()
	check("Stop after everyone left: map gone", tostring(s3.map.Parent) .. " " .. tostring(workspaceSnapshot() == workspaceBefore), "nil true")

	-- The arcade's Back to Lobby pad (Map.Room.Spawn.LobbyPad, tagged LobbyTeleporter): Enabled everywhere but
	-- the shift. Mode.PlayerLeft (the arcade calls it when someone takes the pad): that player loses, the rest
	-- play on; when nobody is left the game ends at once.
	table.clear(fired)
	local cy, di = fakePlayer("Cy", "player"), fakePlayer("Di", "spectator")
	local s5 = Mode.Start({ cy, di }, { store = store, manual = true, rng = Random.new(9) })
	local pad = s5.lobbyPad
	local padStates = {}
	local function padNote()
		table.insert(padStates, s5.game.state .. "=" .. tostring(pad and pad:GetAttribute("Enabled")))
	end
	Mode.step(1)
	padNote()
	Mode.play(cy)
	Mode.step(MGame.TICK)
	padNote()
	Mode.step(MC.modeSelectSeconds)
	Mode.step(MC.modeConfirmSeconds)
	padNote()
	check("lobby pad: in the map, tagged LobbyTeleporter, Enabled in the room and mode select, off in the shift",
		tostring(pad ~= nil and pad:IsDescendantOf(s5.map) and game:GetService("CollectionService"):HasTag(pad, "LobbyTeleporter"))
		.. " " .. table.concat(padStates, " "), "true Idle=true ModeSelect=true Shift=false")
	s5.game.score = 25
	Mode.PlayerLeft(cy)
	Mode.PlayerLeft(fakePlayer("Stranger", nil)) -- not in this game: ignored
	Mode.step(MGame.TICK)
	flush()
	check("PlayerLeft of one of two mid-shift: marked left, the shift goes on", tostring(s5.left[cy]) .. " " .. s5.game.state .. " " .. #fired,
		"true Shift 0")
	s5.game.timeLeft = 0
	Mode.step(MGame.TICK) -- Results
	padNote()
	check("lobby pad back on in Results", padStates[4], "Results=true")
	Mode.step(MC.resultsSeconds)
	Mode.step(MGame.TICK)
	flush()
	check("the one who took the pad loses, the one who stayed wins",
		#fired .. " " .. tostring(fired[1] and fired[1][1].won) .. " " .. tostring(fired[1] and fired[1][2].won), "1 false true")
	Mode.Stop()
	table.clear(fired)
	local solo = fakePlayer("Solo", "player")
	local s6 = Mode.Start({ solo }, { store = store, manual = true, rng = Random.new(10) })
	Mode.step(1)
	Mode.PlayerLeft(solo)
	flush()
	check("PlayerLeft of the last player (in the room): Finished at once, won = false; again does nothing",
		#fired .. " " .. tostring(fired[1] and fired[1][1].won) .. " " .. tostring(s6.finished) .. " " .. tostring((pcall(Mode.PlayerLeft, solo))) .. " " .. #fired,
		"1 false true true 1")
	Mode.Stop()

	-- Nobody presses Play: after roomIdleSeconds the game ends and nobody wins.
	table.clear(fired)
	local idler = fakePlayer("Idle", "player")
	local s4 = Mode.Start({ idler }, { store = store, manual = true, rng = Random.new(8) })
	s4.game.score = 99 -- even a stray score can't win a game that never left the room
	Mode.step(MC.roomIdleSeconds - 1)
	flush()
	check("room: still waiting 1 s before roomIdleSeconds", s4.game.state .. " " .. #fired, "Idle 0")
	Mode.step(1.2)
	flush()
	check("nobody pressed Play: Finished once, won = false for everyone, prompt off, demo stopped",
		#fired .. " " .. tostring(fired[1] and fired[1][1].won) .. " " .. s4.game.state .. " " .. tostring(s4.prompt.Enabled), "1 false Done false")
	Mode.Stop()
	check("Play after Stop does nothing", Mode.play(idler), false)

	-- The longest game: every ticket is matched the moment it is active, so ORDER UPs (and their time
	-- bonuses) come as fast as the hold allows, and mode select runs its full countdown.
	table.clear(fired)
	local longPlayer = fakePlayer("Long", "player")
	local sLong
	local instant = { get = function()
		local t = sLong and sLong.game:activeTicket()
		local list = {}
		if t then
			for cell, tower in pairs(t.target) do list[cell] = tower end
		end
		return { blocks = blocksFor(list) }
	end, status = function() return "fake" end }
	sLong = Mode.Start({ longPlayer }, { store = instant, manual = true, rng = Random.new(7) })
	local simulated, dt = 0, 0.5
	while simulated < MC.roomIdleSeconds - 1 do -- Play at the last moment
		Mode.step(dt)
		simulated += dt
	end
	Mode.play(longPlayer)
	while #fired == 0 and simulated < Mode.MaxDuration + 60 do
		Mode.step(dt)
		simulated += dt
		if simulated % 10 == 0 then flush() end
	end
	flush()
	check("longest game (every ticket matched at once): bonus capped at maxTimeBonus, Finished within MaxDuration",
		tostring(sLong.game.bonusUsed) .. " " .. tostring(#fired == 1) .. " " .. tostring(simulated <= Mode.MaxDuration)
		.. " (" .. simulated .. " s simulated, " .. #sLong.game.completed .. " tickets)",
		MC.maxTimeBonus .. " true true (" .. simulated .. " s simulated, " .. #sLong.game.completed .. " tickets)")
	check("...and it ran the room wait, the whole shift and every bonus second", simulated >= MC.roomIdleSeconds - 1 + MC.shiftSeconds + MC.maxTimeBonus, true)
	Mode.Stop()

	finishedConn:Disconnect()
	flush()
	check("Lighting unchanged after full runs (server side never touches it)", lightingSnapshot() == lightingBefore, true)
	check("Workspace unchanged after every Stop", workspaceSnapshot(), workspaceBefore)
	modeCopy:Destroy()
else
	check("ServerStorage.Modes.PatternMatch has Module and Map", false, true)
end

return string.format("%d passed, %d failed\n", passed, failed) .. table.concat(lines, "\n")
