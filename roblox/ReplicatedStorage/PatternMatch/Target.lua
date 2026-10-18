-- ReplicatedStorage.PatternMatch.Target
-- Random target patterns and checking the live grid against them.
--
-- A target maps cell -> tower, a list of color names bottom to top, e.g. { A1 = {"red"}, B2 = {"red", "teal"} }
-- (B2 wants a red block on the table with a teal one on top of it).
-- A live grid comes from Grid.liveGridFrom: cell -> { [level] = { color, ... } }, level 0 = table.
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

-- n blocks in towers no taller than maxHeight (1 = flat, clamped to Config.maxStackGlobal), on at most
-- every cell once, with random (possibly repeating) colors, within a tower too. After the first block,
-- each block goes on top of a tower that still has room with probability Config.stackChance (always,
-- once every cell is taken), otherwise on a fresh cell. rng is an optional Random, for repeatable tests.
function Target.generate(n, maxHeight, rng)
	rng = rng or Random.new()
	maxHeight = math.clamp(maxHeight or 1, 1, Config.maxStackGlobal)
	local free = Grid.allCells()
	local colors = palette()
	assert(n >= 0 and n <= #free * maxHeight, "Target.generate: n must be between 0 and " .. #free * maxHeight)
	assert(#colors > 0, "Target.generate: Config.colors is empty")

	local target = {}
	local open = {} -- target cells whose tower is still shorter than maxHeight
	for _ = 1, n do
		local color = colors[rng:NextInteger(1, #colors)]
		local stack = #open > 0 and (#free == 0 or rng:NextNumber() < Config.stackChance)
		if stack then
			local k = rng:NextInteger(1, #open)
			local cell = open[k]
			table.insert(target[cell], color)
			if #target[cell] >= maxHeight then
				table.remove(open, k)
			end
		else
			local cell = table.remove(free, rng:NextInteger(1, #free))
			target[cell] = { color }
			if maxHeight > 1 then
				table.insert(open, cell)
			end
		end
	end
	return target
end

-- Total blocks and tallest tower in a target.
function Target.count(target)
	local blocks, tallest = 0, 0
	for _, tower in pairs(target) do
		blocks += #tower
		tallest = math.max(tallest, #tower)
	end
	return blocks, tallest
end

local function addLevel(problemLevels, cell, level)
	local levels = problemLevels[cell]
	if not levels then
		levels = {}
		problemLevels[cell] = levels
	end
	levels[level] = true
end

-- Compares level by level. Returns { clear, missing, wrong, extra, blocked, doubled, problemLevels }, the
-- five lists sorted arrays of cells:
--   missing: target cell with a tower level that has no block (nothing at all, or a shorter tower)
--   wrong:   target cell with a block of the wrong color at some level
--   extra:   block at a level the target tower doesn't have (on top of a complete tower, or on a
--            non-target cell), or at any level >= Config.maxStackGlobal
--   blocked: any block on a vanished cell (reported here instead of the lists above)
--   doubled: 2+ blocks reported at the same cell and level; that level can never count as correct
-- problemLevels: { [cell] = { [level] = true } }, the blocks behind extra, doubled and blocked, so the
-- LiveBoard can outline the specific block.
-- clear is true only when every tower matches exactly bottom to top and nothing else is on the grid,
-- i.e. all five lists are empty. Holding it for Config.holdToClear is the caller's job.
function Target.compare(target, liveGrid, vanished)
	vanished = vanished or {}
	local missing, wrong, extra, blocked, doubled = {}, {}, {}, {}, {}
	local problemLevels = {}

	for cell, entry in pairs(liveGrid) do
		local tower = target[cell] or {}
		for _, level in ipairs(Grid.levelsOf(entry)) do
			local colors = entry[level]
			if vanished[cell] then
				blocked[cell] = true
				addLevel(problemLevels, cell, level)
			else
				if #colors >= 2 then
					doubled[cell] = true
					addLevel(problemLevels, cell, level)
				end
				if level >= Config.maxStackGlobal or tower[level + 1] == nil then
					extra[cell] = true
					addLevel(problemLevels, cell, level)
				elseif #colors == 1 and colors[1] ~= tower[level + 1] then
					wrong[cell] = true
				end
			end
		end
	end

	for cell, tower in pairs(target) do
		if not blocked[cell] then
			local entry = liveGrid[cell] or {}
			for i = 1, #tower do
				if entry[i - 1] == nil then
					missing[cell] = true
				end
			end
		end
	end

	local result = {
		missing = sortedKeys(missing),
		wrong = sortedKeys(wrong),
		extra = sortedKeys(extra),
		blocked = sortedKeys(blocked),
		doubled = sortedKeys(doubled),
		problemLevels = problemLevels,
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
