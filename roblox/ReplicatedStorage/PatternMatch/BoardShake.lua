-- ReplicatedStorage.PatternMatch.BoardShake
-- Tremor board shake, run on each client (StarterGui.PatternHud): jitters the board Models every frame
-- and, on stop, puts them back exactly where they were. The moves are local to that client; the
-- server's copy of the boards never changes.
-- Restore pivots the whole Model back, then sets each anchored part's exact saved CFrame. Unanchored
-- parts (the arm twin's links, which hang off its anchored base through Motor6Ds) are only moved by
-- the pivot, so the arm keeps whatever pose it reached during the shake.
--   local shake = BoardShake.start({ targetBoardModel, liveBoardModel })
--   shake:stop()

local RunService = game:GetService("RunService")

local SHAKE_STUDS = 0.15
local SHAKE_RADIANS = math.rad(1)

local BoardShake = {}
BoardShake.__index = BoardShake

function BoardShake.start(boards, rng)
	rng = rng or Random.new()
	local saved, pivots = {}, {}
	for _, board in ipairs(boards) do
		pivots[board] = board:GetPivot()
		for _, part in ipairs(board:GetDescendants()) do
			if part:IsA("BasePart") and part.Anchored then
				saved[part] = part.CFrame
			end
		end
	end
	local connection = RunService.Heartbeat:Connect(function()
		for board, pivot in pairs(pivots) do
			local offset = CFrame.new(rng:NextNumber(-SHAKE_STUDS, SHAKE_STUDS), 0, rng:NextNumber(-SHAKE_STUDS, SHAKE_STUDS))
				* CFrame.Angles(0, rng:NextNumber(-SHAKE_RADIANS, SHAKE_RADIANS), 0)
			board:PivotTo(pivot * offset)
		end
	end)
	return setmetatable({ saved = saved, pivots = pivots, connection = connection }, BoardShake)
end

function BoardShake:stop()
	if not self.connection then
		return
	end
	self.connection:Disconnect()
	self.connection = nil
	for board, pivot in pairs(self.pivots) do
		board:PivotTo(pivot)
	end
	for part, cframe in pairs(self.saved) do
		part.CFrame = cframe
	end
end

return BoardShake
