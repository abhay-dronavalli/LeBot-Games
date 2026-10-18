-- ReplicatedStorage.PatternMatch.BoardShake
-- Tremor board shake, run on each client (StarterGui.PatternHud): jitters the board Models every frame
-- and, on stop, puts every part back exactly where it was. The moves are local to that client; the
-- server's copy of the boards never changes.
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
			if part:IsA("BasePart") then
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
	return setmetatable({ saved = saved, connection = connection }, BoardShake)
end

function BoardShake:stop()
	if not self.connection then
		return
	end
	self.connection:Disconnect()
	self.connection = nil
	for part, cframe in pairs(self.saved) do
		part.CFrame = cframe
	end
end

return BoardShake
