--!strict
-- The arena's audio. Same warm/cool split as the colours: dragon sounds are low and heavy, player
-- sounds are high and bright, so you can tell who did something without looking.
--
-- THE ASSET IDS ARE DELIBERATELY EMPTY. Picking them means browsing the Roblox audio library and
-- listening, and an invented rbxassetid is worse than none: it either fails silently or plays
-- something nobody chose. Fill SOUND in from the library (Creator Store -> Audio, filter to free),
-- and check the licence on anything you add - no copyrighted music. Every call here no-ops on a
-- zero id, so the mode runs silent until they are filled rather than erroring.
--
--   local sound = Sound.new(workspace)
--   sound:ambience(); sound:slam(at); sound:fireStart(head)

local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local Sound = {}
Sound.__index = Sound

-- rbxassetid://... Leave at 0 for silence.
local SOUND = {
	ambience   = 0,   -- low volcano rumble, bubbling lava; loops under everything
	roar       = 0,   -- the dragon's roar, on the frame fire starts
	flame      = 0,   -- looping flame roar, while fire lasts
	slam       = 0,   -- deep boom
	sweep      = 0,   -- grinding scrape, loops while sweeping
	pickup     = 0,   -- bright chime
	debuff     = 0,   -- zap, when a player lands an effect
	eliminated = 0,   -- pop
	tick       = 0,   -- the last ten seconds
}

local function make(id: number, parent: Instance, volume: number, looped: boolean?): Sound?
	if id == 0 then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = "rbxassetid://" .. id
	s.Volume = volume
	s.Looped = looped or false
	s.RollOffMaxDistance = 400
	s.Parent = parent
	return s
end

function Sound.new(parent: Instance)
	local self = setmetatable({}, Sound)
	self.parent = parent
	self.loops = {} :: { [string]: Sound }
	return self
end

-- A one-off at a place in the world, cleaned up after it finishes.
function Sound.at(self, key: string, at: Vector3, volume: number?)
	local id = SOUND[key]
	if not id or id == 0 then
		return
	end
	local host = Instance.new("Part")
	host.Size = Vector3.new(1, 1, 1)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CFrame = CFrame.new(at)
	host.Parent = self.parent
	local s = make(id, host, volume or 0.6)
	if s then
		s:Play()
	end
	Debris:AddItem(host, 6)
end

-- A one-off with no position: UI feedback, which should not get quieter across the arena.
function Sound.ui(self, key: string, volume: number?)
	local id = SOUND[key]
	if not id or id == 0 then
		return
	end
	local s = make(id, SoundService, volume or 0.5)
	if s then
		s:Play()
		Debris:AddItem(s, 6)
	end
end

-- A loop tied to a part, so the flame roar and the sweep scrape come from the head.
function Sound.startLoop(self, key: string, host: Instance, volume: number?)
	if self.loops[key] then
		return
	end
	local s = make(SOUND[key], host, volume or 0.5, true)
	if s then
		s:Play()
		self.loops[key] = s
	end
end

function Sound.stopLoop(self, key: string)
	local s = self.loops[key]
	if s then
		s:Stop()
		s:Destroy()
		self.loops[key] = nil
	end
end

function Sound.ambience(self)
	self:startLoop("ambience", SoundService, 0.35)
end

return Sound
