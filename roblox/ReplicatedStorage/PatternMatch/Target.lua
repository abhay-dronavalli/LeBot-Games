-- ReplicatedStorage.PatternMatch.Target
-- Random target patterns and checking the live grid against them.
--
-- A target maps cell -> color name, e.g. { A1 = "red", C2 = "teal" }.
-- A live grid comes from Grid.liveGridFrom: cell -> { colors = {...}, stacked = n }.
-- vanished is a set of cells, e.g. { B3 = true }.

local Config = require(script.Parent.Config)
local Grid = require(script.Parent.Grid)

local Target = {}

-- Color names from Config.colors, sorted so a seeded rng gives the same pattern every time.
local function palette()
	local names = {}
	for name in pairs(Config.colors) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function sortedKeys(set)
	local list = {}
	for key in pairs(set) do
		table.insert(list, key)
	end
	table.sort(list)
	return list
end

-- n random cells, no two on the same cell, with random (possibly repeating) colors.
-- rng is an optional Random, for repeatable tests.
function Target.generate(n, rng)
	rng = rng or Random.new()
	local cells = Grid.allCells()
	local colors = palette()
	assert(n >= 0 and n <= #cells, "Target.generate: n must be between 0 and " .. #cells)
	assert(#colors > 0, "Target.generate: Config.colors is empty")

	-- Partial Fisher-Yates: the first n cells end up a random distinct sample.
	local target = {}
	for i = 1, n do
		local j = rng:NextInteger(i, #cells)
		cells[i], cells[j] = cells[j], cells[i]
		target[cells[i]] = colors[rng:NextInteger(1, #colors)]
	end
	return target
end

-- Returns { clear, missing, wrong, extra, blocked, doubled }, each list a sorted array of cells:
--   missing: target cell with no block on the table
--   wrong:   target cell whose block is the wrong color
--   extra:   block on a non-target cell, or a stacked block (level > 0) on any cell
--   blocked: any block on a vanished cell (reported here instead of the lists above)
--   doubled: 2+ blocks on the table in one cell; that cell can never count as correct
-- clear is true only when all lists are empty. Holding it for Config.holdToClear is the caller's job.
function Target.compare(target, liveGrid, vanished)
	vanished = vanished or {}
	local missing, wrong, extra, blocked, doubled = {}, {}, {}, {}, {}

	for cell, entry in pairs(liveGrid) do
		if vanished[cell] then
			blocked[cell] = true
		else
			if #entry.colors >= 2 then
				doubled[cell] = true
			end
			if entry.stacked > 0 or target[cell] == nil then
				extra[cell] = true
			end
		end
	end

	for cell, want in pairs(target) do
		local entry = liveGrid[cell]
		if not blocked[cell] and not doubled[cell] then
			if entry == nil or #entry.colors == 0 then
				missing[cell] = true
			elseif entry.colors[1] ~= want then
				wrong[cell] = true
			end
		end
	end

	local result = {
		missing = sortedKeys(missing),
		wrong = sortedKeys(wrong),
		extra = sortedKeys(extra),
		blocked = sortedKeys(blocked),
		doubled = sortedKeys(doubled),
	}
	result.clear = #result.missing == 0 and #result.wrong == 0 and #result.extra == 0
		and #result.blocked == 0 and #result.doubled == 0
	return result
end

-- One-line summary of a compare result, for logs.
function Target.describe(result)
	local parts = { "clear=" .. tostring(result.clear) }
	for _, key in ipairs({ "missing", "wrong", "extra", "blocked", "doubled" }) do
		table.insert(parts, key .. "={" .. table.concat(result[key], ",") .. "}")
	end
	return table.concat(parts, " ")
end

return Target
