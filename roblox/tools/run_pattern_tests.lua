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

section("14. built boards")
local boardView, VIEW_OK -- set in section 14, reused in section 23
local cab = workspace:FindFirstChild("PatternCabinet")
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
	check("rendering only: table-cm data mapping unchanged (A1 / A4 / C1 corners of the sheet)",
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
	local room = workspace:FindFirstChild("Room")
	local spawnPad = room and room:FindFirstChildWhichIsA("SpawnLocation", true)
	check("bedroom built; Baseplate, old SpawnLocation, sky island and cabinet floor gone", room ~= nil and workspace:FindFirstChild("Baseplate") == nil
		and workspace:FindFirstChild("SpawnLocation") == nil and cab:FindFirstChild("Island") == nil and cab:FindFirstChild("Floor") == nil, true)
	check("spawn inside the room, near the entry pad", spawnPad ~= nil and (spawnPad.Position - cab.Entry.Position).Magnitude < 12, true)
	local scriptsInRoom = 0
	for _, d in ipairs(room and room:GetDescendants() or {}) do
		if d:IsA("LuaSourceContainer") then scriptsInRoom += 1 end
	end
	check("no scripts inside the room's props", scriptsInRoom, 0)
	local focus = game:GetService("Lighting"):FindFirstChild("CabinetFocus")
	check("Lighting: Realistic style, shadows on, CabinetFocus depth of field", game:GetService("Lighting").LightingStyle == Enum.LightingStyle.Realistic
		and game:GetService("Lighting").GlobalShadows and focus ~= nil and focus:IsA("DepthOfFieldEffect"), true)
	local blockMesh = RS.PatternMatch:FindFirstChild("BlockMesh")
	table.insert(lines, "     (BlockMesh template: " .. (blockMesh and blockMesh.MeshId or "missing, plain Parts") .. ")")
else
	check("Workspace.PatternCabinet exists", false, true)
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
	local sent, fired, changes = {}, {}, {}
	local g = Game.new({
		cabinet = board,
		store = { get = function() return { blocks = fakeBlocks } end },
		core = { fire = function(name, intensity, duration) table.insert(fired, name .. " " .. intensity .. " " .. duration) end },
		ui = { FireAllClients = function(_, p) table.insert(sent, p) end, FireClient = function() end },
		stateChanged = { Fire = function(_, info) table.insert(changes, info) end },
		rng = Random.new(11),
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
	Config.debugEventEvery = 100000 -- no events in this section

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

	section("16b. switching the active ticket")
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
	local partial = Target.compare(g:activeTicket().target, g.liveGrid, g.events.vanished)
	check("A1 already counts: only B1 is missing, nothing extra or wrong", Target.describe(partial),
		"clear=false missing={B1} wrong={} extra={} blocked={} doubled={}")
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

	section("19. vanish during a shift: sticky rule, blocked compare, white outline, active ticket's cells kept")
	Config.events = { "vanish" }
	Config.debugEventEvery = 4
	fakeBlocks = {}
	startEasy()
	local active = g:activeTicket()
	setPattern(active, { A1 = "red", B2 = "teal", C3 = "yellow" })
	steps(7, 0.25) -- 1.75 s
	check("1.75 s: no event yet", tostring(sent[#sent].event), "nil")
	g:step(0.25) -- 2.0 s: warning, 2 s before the 4 s mark
	check("2.0 s: vanish warning, 2 s", sent[#sent].event.name .. " " .. sent[#sent].event.phase .. " " .. sent[#sent].event.timeLeft, "vanish warning 2")
	steps(8, 0.25) -- 4.0 s
	check("4.0 s: vanish active", g.events.current.phase, "active")
	local vanishedNow = sent[#sent].vanishedCells
	local onTarget = 0
	for _, c in ipairs(vanishedNow) do if active.target[c] then onTarget += 1 end end
	check("1-2 cells vanished, none in the ACTIVE ticket's pattern", #vanishedNow >= 1 and #vanishedNow <= 2 and onTarget == 0, true)
	local v1, v2 = vanishedNow[1], vanishedNow[2]
	check("vanished square transparent, the dark groove layer shows under it", board.LiveBoard[v1].Transparency == 1
		and board.LiveBoard.Base.Color.R < 0.15, true)
	check("TargetBoard unchanged", board.TargetBoard[v1].Transparency, 0)
	fakeBlocks = blocksFor({ A1 = "red", B2 = "teal", C3 = "yellow" })
	table.insert(fakeBlocks, block(v1, "red"))
	steps(8, 0.25) -- 6.0 s: pattern built, but a block sits on a vanished cell
	check("built + block on a vanished cell: not completed", sent[#sent].completedCount, 0)
	check("compare reports it as blocked", Target.compare(active.target, g.liveGrid, g.events.vanished).blocked, { v1 })
	check("white outline on the blocked cell's block", board.LiveBoard.Blocks[v1].ProblemHighlight.Visible, true)
	steps(20, 0.25) -- 11.0 s: the 6 s vanish timer ran out at 10 s
	check("timer over, block still there: cell stays vanished", board.LiveBoard[v1].Transparency, 1)
	if v2 then
		check("the other vanished cell (no block) came back", board.LiveBoard[v2].Transparency, 0)
	end
	check("ticket still not completed", sent[#sent].completedCount, 0)
	fakeBlocks = blocksFor({ A1 = "red", B2 = "teal", C3 = "yellow" })
	g:step(0.25)
	check("block removed: cell comes back", board.LiveBoard[v1].Transparency .. " " .. table.concat(sent[#sent].vanishedCells, ","), "0 ")
	steps(4, 0.25)
	check("then the ticket completes", sent[#sent].completedCount, 1)
	check("vanish never calls Core.Events", #fired, 0)

	section("20. scheduler: only during the Shift, never the same event twice in a row")
	Config.events = { "vanish", "tremor", "inverted" }
	Config.debugEventEvery = 3
	local baseBefore = board.LiveBoard.Base.CFrame
	local blockBefore = board.LiveBoard.Blocks.A1.CFrame
	table.clear(fired)
	local seq, outside, lastActive = {}, 0, nil
	local function watch()
		local ev = g.events.current
		if ev and g.state ~= "Shift" then outside += 1 end
		if ev and ev.phase == "active" and ev ~= lastActive then
			table.insert(seq, ev.name)
			lastActive = ev
		end
	end
	fakeBlocks = {}
	g:setState("Idle")
	g:start(tester)
	for _ = 1, 66 do g:step(0.25); watch() end -- 15 s of ModeSelect + 1.5 s confirmation
	check("ModeSelect: no events, no Core.Events calls", #seq .. " " .. #fired .. " " .. g.state, "0 0 Shift")
	check("shift start: schedule reset", g.events.nextAt, 3)
	for _ = 1, Config.shiftSeconds * 4 do g:step(0.25); watch() end -- the whole shift, empty grid
	check("shift timed out", g.state, "Results")
	check("server never moved the boards (tremor shake is client-side)", board.LiveBoard.Base.CFrame == baseBefore and board.LiveBoard.Blocks.A1.CFrame == blockBefore, true)
	for _ = 1, 8 do g:step(0.25); watch() end
	check("no event outside the Shift; scheduler stopped in Results", outside .. " " .. tostring(g.events.running), "0 false")
	local repeats = 0
	for i = 2, #seq do
		if seq[i] == seq[i - 1] then repeats += 1 end
	end
	check("the shift ran at least 5 events", #seq >= 5, true)
	check("back-to-back repeats in " .. #seq .. " events", repeats, 0)
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
	check("ticket clicks are ignored outside the shift", g:selectTicket(alice, 1), false)
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
	local shakingNow = true
	local targetSpinner = BoardSpinner.new(board.TargetBoard, { isShaking = function() return shakingNow end })
	local tlook0, ta1Start = board.TargetBoard.Base.CFrame.LookVector, board.TargetBoard.A1.Position
	targetSpinner:request()
	task.wait(0.6)
	check("during a tremor the spin waits", board.TargetBoard.Base.CFrame.LookVector:Dot(tlook0) > 0.9999, true)
	shakingNow = false
	local took = waitIdle(targetSpinner, 3)
	check("tremor over: the spin runs, after the 0.5 s margin", math.abs(board.TargetBoard.Base.CFrame.LookVector:Dot(tlook0)) < 0.001
		and took >= BoardSpinner.AFTER_SHAKE_SECONDS + BoardSpinner.SPIN_SECONDS - 0.05, true)
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

return string.format("%d passed, %d failed\n", passed, failed) .. table.concat(lines, "\n")
