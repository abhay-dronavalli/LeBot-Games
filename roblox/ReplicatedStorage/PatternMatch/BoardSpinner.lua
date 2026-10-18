-- ReplicatedStorage.PatternMatch.BoardSpinner
-- Spins one board 90 degrees around its vertical center axis per request, run on the server so every
-- player sees the same orientation. Visual only: tiles, block parts and outlines all turn with the
-- Model, and Grid.worldPositionOf follows the Base, so cells keep their blocks.
-- Requests queue: one spin at a time, and none while isShaking() says a tremor is on (clients shake
-- the boards locally then), plus a short margin after it ends so their restore lands first.
-- Only a board with a SpinClick ClickDetector spins (the TargetBoard). Requests on any other board, the
-- LiveBoard with the arm twin, are ignored: it stays fixed like the real table.
--   local spinner = BoardSpinner.new(boardModel, { isShaking = function() return false end })
--   spinner:request()

local RunService = game:GetService("RunService")

local SPIN_SECONDS = 0.3
local SPIN_ANGLE = -math.pi / 2 -- clockwise seen from above
local AFTER_SHAKE_SECONDS = 0.5

local BoardSpinner = {}
BoardSpinner.__index = BoardSpinner
BoardSpinner.SPIN_SECONDS = SPIN_SECONDS
BoardSpinner.AFTER_SHAKE_SECONDS = AFTER_SHAKE_SECONDS

-- opts: isShaking (optional function returning true while a tremor is active)
function BoardSpinner.new(board, opts)
	opts = opts or {}
	local self = setmetatable({}, BoardSpinner)
	self.board = board
	self.spinnable = board:FindFirstChild("SpinClick") ~= nil
	self.isShaking = opts.isShaking or function()
		return false
	end
	self.pending = 0
	self.spin = nil -- { from, elapsed } while turning
	self.lastShake = -math.huge
	self.connection = RunService.Heartbeat:Connect(function(dt)
		self:update(dt)
	end)
	return self
end

function BoardSpinner:request()
	if not self.spinnable then
		return
	end
	self.pending += 1
end

function BoardSpinner:busy()
	return self.spin ~= nil or self.pending > 0
end

function BoardSpinner:update(dt)
	local now = os.clock()
	if self.isShaking() then
		self.lastShake = now
	end
	local spin = self.spin
	if spin then
		spin.elapsed = math.min(spin.elapsed + dt, SPIN_SECONDS)
		local t = spin.elapsed / SPIN_SECONDS
		local eased = 1 - (1 - t) * (1 - t) -- quad out
		self.board:PivotTo(spin.from * CFrame.Angles(0, SPIN_ANGLE * eased, 0))
		if spin.elapsed >= SPIN_SECONDS then
			self.spin = nil
		end
	elseif self.pending > 0 and not self.isShaking() and now - self.lastShake >= AFTER_SHAKE_SECONDS then
		self.pending -= 1
		self.spin = { from = self.board:GetPivot(), elapsed = 0 }
	end
end

function BoardSpinner:destroy()
	self.connection:Disconnect()
end

return BoardSpinner
