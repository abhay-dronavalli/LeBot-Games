--!strict
-- Works out what the dragon is doing from the arm's own motion, as it happens.
--
-- There is no "attack" message on the wire and there cannot be one: the operator is a person
-- holding a leader arm, and nothing upstream knows they are about to slam. So the server watches
-- successive state frames and decides. This is also why hard rule 1 forbids predictive telegraphs -
-- the game finds out at the same instant the players do.
--
-- TIMING COMES FROM `ts`, NOT FROM HEARTBEAT. Bridge keeps only the newest frame and drops the
-- rest, so the gap between the frames actually seen is not Heartbeat's delta time. Dividing a real
-- position change by the wrong dt invents speed, and invented speed fires slams that never
-- happened. Every velocity here is differentiated from the frame's own `ts`.
--
-- EVERY THRESHOLD IS A GUESS. The numbers in ArenaConfig are starting values from the style guide,
-- not measurements. Log real tip speed in teleop and set them from that - and remember the follower
-- caps its own per-tick movement (`max_relative_target = 10` in robot/arm.py), so its top speed is
-- bounded and a threshold above that can never fire at all.
--
--   local detect = AttackDetect.new()
--   detect.onSlam = function(tipMm, speed) ... end
--   every new state frame: detect:update(s)   (Module, from Link.state())

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)

local AttackDetect = {}
AttackDetect.__index = AttackDetect

function AttackDetect.new()
	local self = setmetatable({}, AttackDetect)
	self.history = {} :: { { x: number, y: number, z: number, ts: number } }
	self.vel = { x = 0, y = 0, z = 0 }
	self.armed = true            -- a slam needs the tip to have lifted since the last one
	self.sweeping = false
	self.firing = false
	self.dormant = false
	self.lastTs = nil :: number?

	-- The jaw's observed range, learned exactly as DragonArm does and for the same reason: what
	-- reading means "open" differs from gripper to gripper.
	self.gripLo = nil :: number?
	self.gripHi = nil :: number?

	-- Hooks. Set whichever matter; an unset one is simply not called.
	self.onSlam = nil :: ((tipMm: any, speed: number) -> ())?
	self.onSweepStart = nil :: ((dir: any) -> ())?
	self.onSweep = nil :: ((tipMm: any, dir: any) -> ())?
	self.onSweepEnd = nil :: (() -> ())?
	self.onFireStart = nil :: ((frac: number) -> ())?
	self.onFire = nil :: ((frac: number) -> ())?
	self.onFireEnd = nil :: (() -> ())?
	return self
end

local function call(fn: any, ...)
	if fn then
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[AttackDetect] handler errored: " .. tostring(err))
		end
	end
end

-- Velocity in mm/s, smoothed across the last few frames so one jittery FK sample cannot read as a
-- slam. A gap longer than VELOCITY_MAX_GAP_S means the link stalled rather than the arm moving
-- fast, so the estimate restarts instead of dividing a large move by a large dt.
function AttackDetect.updateVelocity(self, tip: any, ts: number)
	local h = self.history
	local last = h[#h]
	if last and ts - last.ts > ArenaConfig.VELOCITY_MAX_GAP_S then
		table.clear(h)
		self.vel = { x = 0, y = 0, z = 0 }
	end
	if last and ts <= last.ts then
		return                   -- a repeated or out-of-order frame carries no new motion
	end

	table.insert(h, { x = tip.x, y = tip.y, z = tip.z, ts = ts })
	while #h > ArenaConfig.VELOCITY_SMOOTH_FRAMES + 1 do
		table.remove(h, 1)
	end
	if #h < 2 then
		return
	end
	local a, b = h[1], h[#h]
	local dt = b.ts - a.ts
	if dt <= 0 then
		return
	end
	self.vel = { x = (b.x - a.x) / dt, y = (b.y - a.y) / dt, z = (b.z - a.z) / dt }
end

-- Jaw opening 0..1 on this gripper's own learned range. Same method as bridge/world.py
-- `_grip_state` and DragonArm:jawFraction.
function AttackDetect.jawFraction(self, grip: number?): number
	if grip == nil then
		return 0
	end
	self.gripLo = self.gripLo and math.min(self.gripLo, grip) or grip
	self.gripHi = self.gripHi and math.max(self.gripHi, grip) or grip
	local span = (self.gripHi :: number) - (self.gripLo :: number)
	if span >= ArenaConfig.GRIP_SPAN_MIN then
		return math.clamp((grip - (self.gripLo :: number)) / span, 0, 1)
	end
	return math.clamp(grip / ArenaConfig.GRIP_OPEN_PCT, 0, 1)
end

function AttackDetect.stopAll(self)
	if self.sweeping then
		self.sweeping = false
		call(self.onSweepEnd)
	end
	if self.firing then
		self.firing = false
		call(self.onFireEnd)
	end
end

function AttackDetect.update(self, state: any)
	local arm = state and state.arm
	if arm == nil or arm.tip == nil then
		return
	end

	-- A stale arm is a harmless dragon (hard rule 5). Stop whatever was running: a fire cone left
	-- burning on a dead link would keep killing players with nobody driving it.
	if (state.arm_age or 0) > ArenaConfig.STALE_ARM_S then
		if not self.dormant then
			self.dormant = true
			self:stopAll()
			table.clear(self.history)
		end
		return
	end
	self.dormant = false

	local ts = state.ts or os.clock()
	self:updateVelocity(arm.tip, ts)

	local floor = ArenaConfig.ARENA_FLOOR_MM
	local height = arm.tip.z - floor          -- how far the real tip is above the arena floor
	local v = self.vel

	self:detectSlam(arm.tip, height, v)
	self:detectSweep(arm.tip, height, v)
	self:detectFire(arm.joints and arm.joints.gripper)
end

-- The tip comes within SLAM_HEIGHT_MM of the arena floor while moving down fast. One slam per
-- descent: without the re-arm, a tip resting near the floor with a little jitter re-triggers every
-- frame and the arena fills with shockwaves.
--
-- `z` is up off the paper, so descending is a negative z velocity.
function AttackDetect.detectSlam(self, tip: any, height: number, v: any)
	if height > ArenaConfig.SLAM_REARM_MM then
		self.armed = true
		return
	end
	if not self.armed then
		return
	end
	if height <= ArenaConfig.SLAM_HEIGHT_MM and -v.z >= ArenaConfig.SLAM_SPEED_MMS then
		self.armed = false
		call(self.onSlam, tip, -v.z)
	end
end

-- The tip is low and moving sideways fast. Sideways is the x/y plane of the sheet; the vertical
-- component is deliberately excluded, or a fast slam would also register as a sweep.
function AttackDetect.detectSweep(self, tip: any, height: number, v: any)
	local lateral = math.sqrt(v.x * v.x + v.y * v.y)
	local low = height <= ArenaConfig.SWEEP_HEIGHT_MM
	local fast = lateral >= ArenaConfig.SWEEP_SPEED_MMS
	local dir = { x = v.x, y = v.y, speed = lateral }

	if low and fast then
		if not self.sweeping then
			self.sweeping = true
			call(self.onSweepStart, dir)
		end
		call(self.onSweep, tip, dir)
	elseif self.sweeping then
		self.sweeping = false
		call(self.onSweepEnd)
	end
end

-- Fire needs BOTH tests, and the second one is the whole point.
--
-- `butterfingers` holds the jaw at least 18% open for its whole duration (BUTTERFINGERS_OPEN_PCT
-- in bridge/effects.py). On the learned range alone a jaw jammed that far open can read as a roar,
-- so a player spending a power-up to jam the dragon's jaw would instead hand it 8 seconds of free
-- fire. The absolute floor, set safely above 18, is what stops that - and it has to be an absolute
-- reading, because the learned range is exactly what the debuff distorts.
function AttackDetect.detectFire(self, grip: number?)
	local frac = self:jawFraction(grip)
	local openEnough = frac >= ArenaConfig.FIRE_OPEN_FRAC
	local aboveJamFloor = (grip or 0) >= ArenaConfig.FIRE_MIN_PCT

	if openEnough and aboveJamFloor then
		if not self.firing then
			self.firing = true
			call(self.onFireStart, frac)
		end
		call(self.onFire, frac)
	elseif self.firing then
		-- Stops on the same frame the jaw drops below the threshold: a fire cone that lingers is a
		-- hit volume the player cannot see.
		self.firing = false
		call(self.onFireEnd)
	end
end

return AttackDetect
