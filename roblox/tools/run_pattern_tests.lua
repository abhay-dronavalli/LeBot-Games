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
	local function blocksFor(target)
		local list = {}
		for cell, color in pairs(target) do table.insert(list, block(cell, color)) end
		return list
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
	local tcell, tcolor = next(g.target)
	local tile = board.TargetBoard[tcell]
	local other
	for _, c in ipairs(cells) do
		if not g.target[c] then other = board.TargetBoard[c] break end
	end
	check("show: target tile in its color", tile.Color == Config.colors[tcolor], true)
	check("show: target tile outlined", tile.TargetOutline.Visible, true)
	steps(19, 0.25) -- 4.75 s
	check("4.75 s: still show, 1 s left on HUD", g.revealPhase .. " " .. sent[#sent].revealTimeLeft, "show 1")
	g:step(0.25) -- 5.0 s
	check("5.0 s: hide", g.revealPhase, "hide")
	check("hide: target tile gray", tile.Color == TargetBoard.HIDDEN, true)
	check("hide: outline stays", tile.TargetOutline.Visible, true)
	check("hide: non-target tile neutral, no outline", other.Color == TargetBoard.NEUTRAL and not other.TargetOutline.Visible, true)
	check("payload revealPhase / revealTimeLeft", sent[#sent].revealPhase .. " " .. sent[#sent].revealTimeLeft, "hide 5")
	steps(20, 0.25) -- 10.0 s
	check("10.0 s: show again", g.revealPhase, "show")
	steps(20, 0.25) -- 15.0 s, back in hide
	check("15.0 s: hide", g.revealPhase, "hide")

	fakeBlocks = blocksFor(g.target)
	steps(4, 0.25) -- clear held for 1 s
	check("solved during hide -> Intermission", g.state, "Intermission")
	check("intermission: full colors", tile.Color == Config.colors[tcolor], true)
	check("intermission: no outline, no reveal in payload", tostring(tile.TargetOutline.Visible) .. " " .. tostring(sent[#sent].revealPhase), "false nil")

	fakeBlocks = {}
	g:step(Config.intermissionSeconds)
	check("round 2 state", g.state .. " " .. g.round, "Round 2")
	check("round 2 reset to show, 5 s left", g.revealPhase .. " " .. math.ceil(g.revealLeft), "show 5")

	section("17. Easy mode unchanged, LiveBoard problem highlight")
	Config.debugForceMode = nil
	startEasy()
	check("debugForceMode=nil: auto-picked Easy, round 1", g.mode .. " " .. g.state, "Easy Round")
	local ecell, ecolor = next(g.target)
	check("easy: no reveal phase, no outline", tostring(g.revealPhase) .. " " .. tostring(board.TargetBoard[ecell].TargetOutline.Visible), "nil false")
	check("easy: target tile in its color", board.TargetBoard[ecell].Color == Config.colors[ecolor], true)

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
	local lit = {}
	for _, c in ipairs(cells) do
		if board.LiveBoard[c].ProblemHighlight.Visible then table.insert(lit, c) end
	end
	local want = { free[1], free[2], ecell }
	table.sort(want)
	check("extra + double + stack cells highlighted", lit, want)
	fakeBlocks = blocksFor(g.target)
	g:step(0.25)
	lit = {}
	for _, c in ipairs(cells) do
		if board.LiveBoard[c].ProblemHighlight.Visible then table.insert(lit, c) end
	end
	check("problems removed -> highlights cleared", lit, {})

	local PatternEvents = require(pm.PatternEvents)

	section("18. vanish cell selection")
	local rng = Random.new(7)
	local badPicks, maxPicked = 0, 0
	for _ = 1, 300 do
		local tgt = Target.generate(rng:NextInteger(3, 5), rng)
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
	check("no empty non-target cell -> nothing picked", PatternEvents.pickVanishCells({ A1 = "red" }, live(fullBoard), {}, 2, rng), {})
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
	check("white outline on the blocked cell", board.LiveBoard[v1].ProblemHighlight.Visible, true)
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
	local shake = BoardShake.start({ board.TargetBoard, board.LiveBoard })
	local moved = false
	for _ = 1, 10 do
		task.wait()
		if board.LiveBoard.Base.CFrame ~= baseStart then moved = true end
	end
	table.insert(lines, "     (boards moved while shaking: " .. tostring(moved) .. ")")
	shake:stop()
	check("after stop: LiveBoard.Base and TargetBoard.C4 exactly restored",
		board.LiveBoard.Base.CFrame == baseStart and board.TargetBoard.C4.CFrame == tileStart, true)

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
	local function offCells()
		local bad = 0
		for _, c in ipairs(cells) do
			local tile = board.LiveBoard[c]
			local d = tile.Position - Grid.worldPositionOf(c, board.LiveBoard)
			local e = board.LiveBoard.Blocks[c].Position - tile.Position
			if Vector3.new(d.X, 0, d.Z).Magnitude > 0.01 or Vector3.new(e.X, 0, e.Z).Magnitude > 0.01 then bad += 1 end
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
	targetSpinner:destroy()
	board:Destroy()
end

return string.format("%d passed, %d failed\n", passed, failed) .. table.concat(lines, "\n")
