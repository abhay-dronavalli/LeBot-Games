-- RunControl -- who owns the crates right now, and how a bay is put back to a fresh state.
--
-- Two scripts need to agree on this and neither should depend on the other: HazardManager owns
-- bay rebuilding, DebugMenu drives it, and BridgeFeed and DebugMode each need to know whether
-- they are the live crate source this minute. A tiny shared module is the seam -- HazardManager
-- fills in the rebuild hooks on startup, everyone else calls them.
--
-- FEED MODES. Exactly one source may own the crates, which is the whole reason this exists:
--
--   "solo"  one player doing both jobs: the on-screen 4x3 grid places blocks and the Sky Arm
--           carries them in, so you are the operator as well as the runner.
--   "live"  the real SO-101 over the WebSocket. Nothing else may place a block.
--
-- Switching modes RESETS THE WORLD -- every bay rebuilt, every crate cleared. The two modes
-- disagree about who owns the crates and about what the arm is doing, so carrying state across
-- the switch leaves crates nobody placed and an arm following nobody.
--
-- The mode is runtime, not a Config constant, because the point is to flip it mid-session
-- while debugging rather than restarting the place to change one boolean.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local RunControl = {}

RunControl.MODES = {"solo", "live"}

RunControl.feedMode = (Config.FeedMode == "live") and "live" or "solo"

local feedChanged = Instance.new("BindableEvent")
RunControl.FeedModeChanged = feedChanged.Event

-- WHICH BAY THE MAT MAPS TO. One physical 4x3 grid serves nine bays, so every crate source
-- has to agree on which one is live right now -- and so does Mapping, whose ORIGIN is derived
-- from that bay's Cell_0_0 anchor. The debug menu drives this today; ActiveBayTracker will
-- drive it from player 1's position, and this is the shape it should take.
RunControl.activeBay = Config.LiveBay or 1

local bayChanged = Instance.new("BindableEvent")
RunControl.ActiveBayChanged = bayChanged.Event

function RunControl.activeBayModel()
	local warehouse = workspace:FindFirstChild("Warehouse")
	return warehouse and warehouse:FindFirstChild(("Bay%02d"):format(RunControl.activeBay))
end

function RunControl.setActiveBay(i)
	i = math.clamp(math.floor(tonumber(i) or 1), 1, Config.NumBays)
	local previous = RunControl.activeBay
	RunControl.activeBay = i
	local bay = RunControl.activeBayModel()
	if bay then
		require(ReplicatedStorage:WaitForChild("Mapping")).setActiveBay(bay)
	end
	if i ~= previous then
		bayChanged:Fire(i, previous)
	end
	return i
end

-- Filled in by HazardManager once it has built the bays. Nothing else may assign these.
RunControl.rebuildBay = nil      -- (bayIndex) -> state; full teardown and rebuild
RunControl.bayState = nil        -- (bayIndex) -> state, for reading `solved`

local readyEvent = Instance.new("BindableEvent")
RunControl.Ready = readyEvent.Event
RunControl.isReady = false

function RunControl.markReady()
	RunControl.isReady = true
	readyEvent:Fire()
end

-- Block until HazardManager has published its hooks. Script execution order is not guaranteed,
-- and a debug menu that silently does nothing because it loaded first is a miserable thing to
-- diagnose.
function RunControl.waitForReady(timeout)
	local deadline = os.clock() + (timeout or 10)
	while not RunControl.isReady and os.clock() < deadline do
		task.wait(0.05)
	end
	return RunControl.isReady
end

function RunControl.isValidMode(mode)
	for _, m in ipairs(RunControl.MODES) do
		if m == mode then
			return true
		end
	end
	return false
end

function RunControl.setFeedMode(mode)
	if not RunControl.isValidMode(mode) or mode == RunControl.feedMode then
		return RunControl.feedMode
	end
	local previous = RunControl.feedMode
	RunControl.feedMode = mode
	print(("[RunControl] crate source: %s -> %s"):format(previous, mode))
	feedChanged:Fire(mode, previous)
	return mode
end

-- Is a real second player driving the arm, as opposed to me clicking a grid?
function RunControl.hasOverseer()
	return RunControl.feedMode == "live"
end

-- Set by HazardManager alongside rebuildBay; used to wipe the world on a mode change.
RunControl.rebuildAll = nil

-- Fired with the bay index after a bay has been rebuilt and its crates cleared.
--
-- Anything holding its own idea of what is in that bay has to drop it here. DebugMode keeps
-- per-bay cell state, and BlockSync.clearBay resets the diff baseline -- so a cell the editor
-- still believes in would be re-delivered on the very next edit, and a crate nobody placed in
-- this run would walk back into a freshly reset bay.
local bayReset = Instance.new("BindableEvent")
RunControl.BayReset = bayReset.Event

function RunControl.notifyBayReset(i)
	bayReset:Fire(i)
end

return RunControl
