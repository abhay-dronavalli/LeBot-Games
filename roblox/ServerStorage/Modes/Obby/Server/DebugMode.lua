-- ServerStorage.Modes.Obby.Server.DebugMode (ModuleScript)
-- DebugMode (Section 10.1) -- the SOLO crate source: the cell editor's backend.
-- Despite the name this is not a debug tool in the arcade: in "solo" the runner places blocks on
-- the on-screen 4x3 grid (Views.Player.CellEditor) and this turns those edits into crate
-- deliveries. Emits the same `cells` structure Section 12.1 defines, so later steps (BlockSync,
-- SkyArm) can't tell the difference between this and the real robot feed. Only its hotkeys
-- (DebugHotkey: 1-9 N T K H M R) are debug, and they only exist with session.debug.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))

-- Exactly one source may own the crates, but WHICH one is a runtime choice now, not a startup
-- constant: the debug menu flips it mid-session. So this script always loads and simply stays
-- quiet unless it is the current source. An earlier version returned here whenever
-- Config.LiveFeed was set, which also took the debug menu out with it.
local RunControl = require(script.Parent:WaitForChild("RunControl"))
local session = RunControl.session

local function isSource()
	return RunControl.feedMode == "solo"
end

local BlockSync = require(script.Parent:WaitForChild("BlockSync"))
local SkyArm = require(script.Parent:WaitForChild("SkyArm"))
-- The arm, the cell editor and the crate deliveries all follow one active bay. RunControl
-- owns which that is -- the debug menu drives it, and ActiveBayTracker will drive the same
-- call from player 1's position. It used to be hardcoded to Bay01, which meant every bay past
-- the first was unreachable by the real flow: you could teleport into Bay 2 and edit cells,
-- but the crates were delivered into Bay 1 behind you.
--
-- Each bay keeps its OWN cell state. Sharing one table would make BlockSync, which diffs per
-- bay model, see every cell vanish from the bay you just left and have the arm dutifully
-- unload it -- which is also why changing bays must NOT clear this.
local warehouse = RunControl.warehouse()

local function activeBayIndexNow()
	return RunControl.activeBay or 1
end

local function targetBayModel()
	return RunControl.activeBayModel() or warehouse:WaitForChild("Bay01")
end

SkyArm.setActiveBay(targetBayModel())

local Remotes = ReplicatedStorage.Obby:WaitForChild("Remotes")
local CellEdit = Remotes:WaitForChild("CellEdit")
local CellsUpdated = Remotes:WaitForChild("CellsUpdated")
local DebugHotkey = Remotes:WaitForChild("DebugHotkey")

-- The editor's echo goes to this round's runners only -- never FireAllClients, which would put
-- the grid's state on every screen in the Workshop.
local function sendCells(list)
	for _, p in ipairs(session.runners) do
		CellsUpdated:FireClient(p, list)
	end
end

local COLOR_CYCLE = {"none", "red", "blue", "yellow", "green", "orange", "purple", "teal"}

-- cellStateByBay[bayIndex][col][row] = {color=, level=} or nil
local cellStateByBay = {}
local previousByBay = {}

local function cellStateFor(bayIndex)
	local cs = cellStateByBay[bayIndex]
	if not cs then
		cs = {}
		cellStateByBay[bayIndex] = cs
	end
	return cs
end

local function buildCellsList()
	local cellState = cellStateFor(activeBayIndexNow())
	local list = {}
	for col = 0, Config.BayCols - 1 do
		for row = 0, Config.BayRows - 1 do
			local cell = cellState[col] and cellState[col][row]
			if cell then
				table.insert(list, {
					col = col,
					row = row,
					color = cell.color,
					level = cell.level,
					ids = (cell.level == 2) and {0, 0} or {0}, -- fake ArUco ids in Debug Mode
				})
			end
		end
	end
	table.sort(list, function(a, b)
		if a.col == b.col then
			return a.row < b.row
		end
		return a.col < b.col
	end)
	return list
end

local function keyFor(c)
	return c.col .. "," .. c.row
end

local function diffCells(oldList, newList)
	local oldByKey, newByKey = {}, {}
	for _, c in ipairs(oldList) do
		oldByKey[keyFor(c)] = c
	end
	for _, c in ipairs(newList) do
		newByKey[keyFor(c)] = c
	end

	local added, removed, changed = {}, {}, {}
	for key, c in pairs(newByKey) do
		local old = oldByKey[key]
		if not old then
			table.insert(added, c)
		elseif old.color ~= c.color or old.level ~= c.level then
			table.insert(changed, c)
		end
	end
	for key, c in pairs(oldByKey) do
		if not newByKey[key] then
			table.insert(removed, c)
		end
	end
	return added, removed, changed
end

local function applyAndBroadcast()
	local newList = buildCellsList()
	local added, removed, changed = diffCells(previousByBay[activeBayIndexNow()] or {}, newList)
	if #added > 0 or #removed > 0 or #changed > 0 then
		print(string.format("[DebugMode] cells diff: +%d -%d ~%d", #added, #removed, #changed))
		for _, c in ipairs(added) do
			print(string.format("  + (%d,%d) %s L%d", c.col, c.row, c.color, c.level))
		end
		for _, c in ipairs(changed) do
			print(string.format("  ~ (%d,%d) %s L%d", c.col, c.row, c.color, c.level))
		end
		for _, c in ipairs(removed) do
			print(string.format("  - (%d,%d) %s L%d", c.col, c.row, c.color, c.level))
		end
	end
	previousByBay[activeBayIndexNow()] = newList
	sendCells(newList)
	BlockSync.applyCells(targetBayModel(), newList)
	return newList
end

-- Follow the active bay. Declared after buildCellsList because a closure only sees locals
-- declared above it -- reading one declared below silently resolves to a nil global.
-- A reset bay has no crates, so the editor must not still think it holds cells. Without this
-- the world and the grid disagree: clearBay wipes the diff baseline, so the next edit re-adds
-- every cell this table still remembers and crates from the previous run reappear.
RunControl.BayReset:Connect(function(i)
	cellStateByBay[i] = nil
	previousByBay[i] = nil
	if i == activeBayIndexNow() then
		sendCells(buildCellsList())
	end
end)

RunControl.ActiveBayChanged:Connect(function()
	SkyArm.setActiveBay(targetBayModel())
	-- re-broadcast so the editor grid shows what is actually in the bay in front of you,
	-- NOT a cleared grid: the per-bay state above is what makes returning to a bay work.
	sendCells(buildCellsList())
end)

session.track(CellEdit.OnServerEvent:Connect(function(player, col, row, action)
	-- only a runner in this round edits the grid; anyone else firing it is ignored
	if not isSource() or not session.isRunner(player) then
		return
	end
	if type(col) ~= "number" or type(row) ~= "number" then
		return
	end
	if col < 0 or col >= Config.BayCols or row < 0 or row >= Config.BayRows then
		return
	end

	local cellState = cellStateFor(activeBayIndexNow())
	cellState[col] = cellState[col] or {}
	local cell = cellState[col][row]

	if action == "toggleLevel" then
		if cell then
			cell.level = (cell.level == 1) and 2 or 1
		end
	else -- "cycle"
		local currentIndex = 1
		if cell then
			for i, name in ipairs(COLOR_CYCLE) do
				if name == cell.color then
					currentIndex = i
					break
				end
			end
		end
		local nextIndex = (currentIndex % #COLOR_CYCLE) + 1
		local nextColor = COLOR_CYCLE[nextIndex]
		if nextColor == "none" then
			cellState[col][row] = nil
		else
			cellState[col][row] = {color = nextColor, level = (cell and cell.level) or 1}
		end
	end

	applyAndBroadcast()
end))

----------------------------------------------------------------
-- Hotkeys (Section 10.1) -- most are stubs until their owning systems (GameState,
-- ActiveBayTracker, Events, SkyArm) exist; they print so the mapping can be verified now.
--
-- Every one of them is a DEBUG key, none is gameplay: 1-9 teleport, N moves the mat without you,
-- R wipes the active bay's cells, and T/K/H/M are print stubs. Placing a block is the grid click
-- (CellEdit above), which is the only part of the editor solo play needs. So the whole handler
-- exists only with session.debug.
----------------------------------------------------------------
local craneActive = false

local function onHotkey(player, key)
	if not session.isRunner(player) then
		return
	end
	if key == "R" then
		cellStateByBay[activeBayIndexNow()] = {}
		applyAndBroadcast()
		print("[DebugMode] R: reset run (cells cleared for the active bay; GameState reset not wired yet)")
	elseif key == "H" then
		craneActive = not craneActive
		print("[DebugMode] H: held Purple crane ->", craneActive)
	elseif key == "T" then
		print("[DebugMode] T: +10s (GameState clock not wired yet)")
	elseif key == "K" then
		print("[DebugMode] K: kill active malfunction (Events not wired yet)")
	elseif key == "M" then
		print("[DebugMode] M: trigger malfunction (Events not wired yet)")
	elseif key == "N" then
		-- moves the arm and the editor without moving the player, for watching a bay fill
		local nextIndex = (activeBayIndexNow() % Config.NumBays) + 1
		RunControl.setActiveBay(nextIndex)
		print("[DebugMode] N: active bay -> " .. nextIndex)
	elseif tonumber(key) then
		local bayIndex = tonumber(key)
		local bayModel = RunControl.bayModel(bayIndex)
		if bayModel then
			-- land on the approach catwalk, not inside the bay: bay 2 has no floor at row 0 and
			-- the old +2 spawned you into thin air over the void. approachCFrame is the same
			-- spot, offset by Config.OriginZ and facing down the course.
			if RunControl.placeCharacter(player, RunControl.approachCFrame(bayIndex)) then
				RunControl.setActiveBay(bayIndex)
				print("[DebugMode] " .. key .. ": teleported to Bay " .. bayIndex .. " (quick-travel, not the real ActiveBayTracker)")
			end
		end
	end
end

if session.debug then
	session.track(DebugHotkey.OnServerEvent:Connect(onHotkey))
end

-- (The old mock-arm sine loop is gone: it ran only under the standalone Config.DebugMode and
-- nothing read its joint angles. The arm's idle motion lives in SkyArm.)

print("[DebugMode] solo crate source (cell editor backend) online"
	.. (session.debug and " -- debug hotkeys on" or ""))

return {}
