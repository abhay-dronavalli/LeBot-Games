-- ServerStorage.Modes.Obby.Server.ActiveBayTracker (ModuleScript)
-- ActiveBayTracker -- the sliding window. Which bay the mat maps to follows the runner.
--
-- This is what was missing when you walked out of bay 1 into bay 2 and nothing happened: the
-- active bay only ever moved when the debug menu or a hotkey moved it, so the mat, the cell
-- editor, the crane and every crate delivery stayed pointed at the bay behind you. Blocks you
-- placed went into bay 1. The grid still showed bay 1.
--
-- It does not do the work itself -- it calls RunControl.setActiveBay, and everything already
-- hangs off that: Mapping re-origins on the new bay's Cell_0_0 anchor, SkyArm slides the crane
-- along the rails, DebugMode swaps to that bay's own cell state, and BridgeFeed clears the bay
-- being left behind.
--
-- THE CATWALK BELONGS TO THE BAY AHEAD. A bay spans BayDepth of its BayPitch and the rest is
-- the catwalk between it and the next. Standing on that catwalk counts as the NEXT bay, so the
-- mat is ready before you walk in rather than a moment after -- the operator needs to be
-- placing while you approach, not catching up once you are already inside. It also keeps this
-- agreeing with the debug menu, whose "start run" drops you on the approach catwalk: without
-- the rule the tracker would immediately drag the window back to the previous bay.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))
local RunControl = require(script.Parent:WaitForChild("RunControl"))

local session = RunControl.session

local SETTLE = 0.35        -- seconds a new bay must hold before the window moves

-- Which bay a world Z sits in, counting the catwalk after a bay as the next one. The arithmetic
-- is in course Z (bay 1's entrance = 0); the map itself sits Config.OriginZ down +Z.
local function bayAt(worldZ)
	local z = RunControl.courseZ(worldZ)
	if z < 0 then
		return 1
	end
	local i = math.floor(z / Config.BayPitch) + 1
	local into = z - (i - 1) * Config.BayPitch
	if into > Config.BayDepth then
		i += 1                -- on the catwalk: the bay ahead is the one being set up
	end
	return math.clamp(i, 1, Config.NumBays)
end

-- The runner drives the window, and the runner is whoever is furthest along. With one player
-- that is simply them. With two it follows the one actually running the course rather than
-- flipping to whoever wandered backwards. Only this round's runners count (session.runners):
-- anyone else in the server is in the Workshop, not on the course.
--
-- Ghosts are excluded: Q is a debug flight mode for touring the course, and having it drag
-- the mat from bay to bay while you fly over them would be useless to the operator.
local function leadBay()
	local best = nil
	for _, pl in ipairs(session.runners) do
		local ch = pl.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 and ch:GetAttribute("Ghost") ~= true then
			local i = bayAt(hrp.Position.Z)
			if best == nil or i > best then
				best = i
			end
		end
	end
	return best
end

local candidate, since = nil, 0

session.track(RunService.Heartbeat:Connect(function(dt)
	local want = leadBay()
	if want == nil or want == RunControl.activeBay then
		candidate, since = nil, 0
		return
	end

	-- Debounced, because standing on a boundary otherwise flaps the window -- and every flap
	-- re-origins Mapping, tweens the crane and clears a bay's crates.
	if want ~= candidate then
		candidate, since = want, 0
		return
	end
	since += dt
	if since >= SETTLE then
		candidate, since = nil, 0
		local from = RunControl.activeBay
		RunControl.setActiveBay(want)
		print(("[ActiveBayTracker] runner moved: bay %d -> %d"):format(from, want))
	end
end))

print("[ActiveBayTracker] online -- the mat follows the runner")

return {}
