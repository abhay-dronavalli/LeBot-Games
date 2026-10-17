-- ReplicatedStorage.PatternMatch.Target
-- Random target patterns and checking the live grid against them.
--
-- A target and a live grid are both maps of cell -> color name, e.g. { A1 = "red", C2 = "teal" }.
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

-- Returns { clear, missing, wrong, extra, blocked }, each list a sorted array of cells:
--   missing: target cell with no block
--   wrong:   target cell with a block of the wrong color
--   extra:   non-target cell with a block
--   blocked: vanished cell with a block (reported here instead of in extra)
-- clear is true only when all four are empty. Holding it for Config.holdToClear is the caller's job.
function Target.compare(target, liveGrid, vanished)
	vanished = vanished or {}
	local missing, wrong, extra, blocked = {}, {}, {}, {}

	for cell, want in pairs(target) do
		local got = liveGrid[cell]
		if vanished[cell] and got ~= nil then
			blocked[cell] = true
		elseif got == nil then
			missing[cell] = true
		elseif got ~= want then
			wrong[cell] = true
		end
	end

	for cell in pairs(liveGrid) do
		if target[cell] == nil then
			if vanished[cell] then
				blocked[cell] = true
			else
				extra[cell] = true
			end
		end
	end

	local result = {
		missing = sortedKeys(missing),
		wrong = sortedKeys(wrong),
		extra = sortedKeys(extra),
		blocked = sortedKeys(blocked),
	}
	result.clear = #result.missing == 0 and #result.wrong == 0 and #result.extra == 0 and #result.blocked == 0
	return result
end

return Target
