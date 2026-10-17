-- ServerScriptService.PatternBoardsDemo
-- TEMPORARY test harness for build step 2. Step 3 (the PatternMode state machine) replaces it.
-- Shows a fixed sample target, redraws the LiveBoard from StateStore every 0.2 s, and prints
-- Target.compare whenever the result changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch.Config)
local Grid = require(PatternMatch.Grid)
local Target = require(PatternMatch.Target)
local LiveBoard = require(PatternMatch.LiveBoard)
local StateStore = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("StateStore"))

local TARGET = { A1 = "red", B2 = "teal", C3 = "yellow" }
local NEUTRAL = Color3.fromRGB(200, 200, 200)

local cabinet = workspace:WaitForChild("PatternCabinet")
local targetBoard = cabinet:WaitForChild("TargetBoard")
local liveBoard = LiveBoard.new(cabinet:WaitForChild("LiveBoard"))

for _, cell in ipairs(Grid.allCells()) do
	local colorName = TARGET[cell]
	targetBoard[cell].Color = colorName and Config.colors[colorName] or NEUTRAL
end

local function cellList(list)
	return "{" .. table.concat(list, ",") .. "}"
end

local function describe(liveGrid, result)
	local live = {}
	for cell, color in pairs(liveGrid) do
		table.insert(live, cell .. "=" .. color)
	end
	table.sort(live)
	return string.format("clear=%s missing=%s wrong=%s extra=%s blocked=%s | live: %s",
		tostring(result.clear), cellList(result.missing), cellList(result.wrong),
		cellList(result.extra), cellList(result.blocked), #live > 0 and table.concat(live, " ") or "(empty)")
end

local last
while true do
	local liveGrid = liveBoard:render(StateStore.get().blocks)
	local text = describe(liveGrid, Target.compare(TARGET, liveGrid, {}))
	if text ~= last then
		print("[PatternBoardsDemo] " .. text)
		last = text
	end
	task.wait(0.2)
end
