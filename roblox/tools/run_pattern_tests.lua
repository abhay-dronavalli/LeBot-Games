-- Pattern Match unit tests. Not part of the game: run in Studio's command bar (or via the MCP
-- execute_luau tool) in Edit mode. Requires clones of the modules, so it never touches the place
-- and never gets stale cached module code. Returns "N passed, M failed" plus one line per check.

local RS = game:GetService("ReplicatedStorage")
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
-- { A1 = "red", ... } -> live grid with one table block at each cell center
local function live(map, more)
	local blocks = {}
	for cell, color in pairs(map) do table.insert(blocks, block(cell, color)) end
	for _, b in ipairs(more or {}) do table.insert(blocks, b) end
	return Grid.liveGridFrom(blocks)
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

local target = { A1 = "red", B2 = "teal", C3 = "yellow" }
table.insert(lines, "-- target used below: A1=red, B2=teal, C3=yellow")
check("compare exact match .clear", Target.compare(target, live(target), {}).clear, true)

section("4. compare with one extra block (purple on A4)")
local r = Target.compare(target, live({ A1 = "red", B2 = "teal", C3 = "yellow", A4 = "purple" }), {})
check(".clear", r.clear, false); check(".extra", r.extra, { "A4" }); check(".missing", r.missing, {})
check(".wrong", r.wrong, {}); check(".blocked", r.blocked, {}); check(".doubled", r.doubled, {})

section("5. compare with a block on a vanished cell (red on vanished B4)")
r = Target.compare(target, live({ A1 = "red", B2 = "teal", C3 = "yellow", B4 = "red" }), { B4 = true })
check(".clear", r.clear, false); check(".blocked", r.blocked, { "B4" }); check(".extra", r.extra, {})
check(".missing", r.missing, {}); check(".wrong", r.wrong, {})
check("same, block removed from B4 .clear", Target.compare(target, live(target), { B4 = true }).clear, true)

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

section("9. stack rule: a block with level > 0 counts as extra for its cell")
local stackOnTarget = live(target, { block("A1", "red", { level = 1, z = 3.5, visible = true }) })
check("live A1 entry: table colors / stacked", table.concat(stackOnTarget.A1.colors, ",") .. " / " .. stackOnTarget.A1.stacked, "red / 1")
r = Target.compare(target, stackOnTarget, {})
check("red on red A1 .clear", r.clear, false); check(".extra", r.extra, { "A1" })
check(".wrong", r.wrong, {}); check(".missing", r.missing, {})
r = Target.compare(target, live(target, { block("A4", "red"), block("A4", "teal", { level = 1 }) }), {})
check("stack on non-target A4 .extra", r.extra, { "A4" }); check(".doubled (stack is not a double)", r.doubled, {})

section("10. doubles rule: 2+ table blocks in one cell")
r = Target.compare(target, live(target, { block("A1", "red", { x = select(1, at(1, 1, 0.3)) }) }), {})
check("two reds in A1 .clear", r.clear, false); check(".doubled", r.doubled, { "A1" })
check(".wrong", r.wrong, {}); check(".missing", r.missing, {}); check(".extra", r.extra, {})
r = Target.compare(target, live(target, { block("B4", "red"), block("B4", "teal") }), {})
check("double on non-target B4 .doubled", r.doubled, { "B4" }); check(".extra", r.extra, { "B4" })
check("describe()", Target.describe(r), "clear=false missing={} wrong={} extra={B4} blocked={} doubled={B4}")

section("11. generate")
local bad = 0
for _ = 1, 500 do
	for _, n in ipairs({ 3, 4, 5, 12 }) do
		local t, count = Target.generate(n), 0
		for cell, color in pairs(t) do
			count += 1
			if not Grid.parseCell(cell) or not Config.colors[color] then bad += 1 end
		end
		if count ~= n then bad += 1 end
	end
end
check("2000 patterns, problems", bad, 0)

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
task.wait()
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
else
	check("Workspace.PatternCabinet exists", false, true)
end

return string.format("%d passed, %d failed\n", passed, failed) .. table.concat(lines, "\n")
