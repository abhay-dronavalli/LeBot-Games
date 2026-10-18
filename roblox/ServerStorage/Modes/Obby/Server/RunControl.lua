-- ServerStorage.Modes.Obby.Server.RunControl (ModuleScript)
-- RunControl -- who owns the crates right now, which bay is live, and the ROUND every other module
-- belongs to.
--
-- Two scripts need to agree on this and neither should depend on the other: HazardManager owns
-- bay rebuilding, DebugMenu drives it, and BridgeFeed and DebugMode each need to know whether
-- they are the live crate source this minute. A tiny shared module is the seam -- HazardManager
-- fills in the rebuild hooks on startup, everyone else calls them.
--
-- THE ROUND (arcade mode, docs/obby-mode-plan.md). ServerStorage.Modes.Obby.Module clones the whole
-- Server folder fresh for every round and requires the clones, so every module here -- this one
-- included -- starts with fresh state and fresh BindableEvents; a listener left over from the last
-- round hangs on an event nothing fires any more. Module sets RunControl.session BEFORE requiring
-- anything else, and the other modules read it at require time:
--
--   session.map          Workspace.ObbyMap (the clone of Modes.Obby.Map)
--   session.warehouse    session.map.Warehouse (Bay01..Bay04, Shell, SkyRails, ...)
--   session.runners      the players in this round who are still running (an array, kept current)
--   session.debug        Config.ArcadeDebug, or the ArcadeDebug attribute on Modes.Obby
--   session.alive        false once Stop has begun: every loop that is not `while folder.Parent`
--                        checks it
--   session.track(conn)  -> conn; disconnected by Stop. Use it for EVERY connection to a signal that
--                        outlives the round: RunService.*, Players.*, a Player or Character signal,
--                        and OnServerEvent on ReplicatedStorage.Obby.Remotes
--   session.spawn(fn, ...) -> thread; task.spawn that Stop cancels if it is still running
--   session.isRunner(player), session.robots() (players whose Role is "robot")
--
-- FEED MODES. Exactly one source may own the crates, which is the whole reason this exists:
--
--   "solo"  one player doing both jobs: the on-screen 4x3 grid places blocks and the Sky Arm
--           carries them in, so you are the operator as well as the runner.
--   "live"  the real SO-101 through the core's robot link. Nothing else may place a block.
--
-- In the arcade Module sets the mode once at Start (live when the core link is up, else solo). The
-- debug menu can still flip it mid-round (Config.ArcadeDebug), which RESETS THE WORLD -- every bay
-- rebuilt, every crate cleared, because the two modes disagree about who owns the crates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))

local RunControl = {}

RunControl.MODES = {"solo", "live"}

RunControl.feedMode = (Config.FeedMode == "live") and "live" or "solo"

-- The round. Set by Module before any other Server module is required; nil only between rounds.
RunControl.session = nil

function RunControl.warehouse()
	local s = RunControl.session
	return s and s.warehouse
end

local feedChanged = Instance.new("BindableEvent")
RunControl.FeedModeChanged = feedChanged.Event

-- WHICH BAY THE MAT MAPS TO. One physical 4x3 grid serves every bay, so every crate source
-- has to agree on which one is live right now -- and so does Mapping, whose ORIGIN is derived
-- from that bay's Cell_0_0 anchor. ActiveBayTracker drives it from the runner's position.
RunControl.activeBay = Config.LiveBay or 1

local bayChanged = Instance.new("BindableEvent")
RunControl.ActiveBayChanged = bayChanged.Event

function RunControl.bayModel(i)
	local warehouse = RunControl.warehouse()
	return warehouse and warehouse:FindFirstChild(("Bay%02d"):format(i))
end

function RunControl.activeBayModel()
	return RunControl.bayModel(RunControl.activeBay)
end

function RunControl.setActiveBay(i)
	i = math.clamp(math.floor(tonumber(i) or 1), 1, Config.NumBays)
	local previous = RunControl.activeBay
	RunControl.activeBay = i
	local bay = RunControl.activeBayModel()
	if bay then
		require(script.Parent:WaitForChild("Mapping")).setActiveBay(bay)
	end
	if i ~= previous then
		bayChanged:Fire(i, previous)
	end
	return i
end

----------------------------------------------------------------
-- World positions. The course was built with bay 1 at Z = 0; the arcade bakes it Config.OriginZ
-- down +Z, and X is untouched. Everything that turns a bay index into a Z goes through here.
----------------------------------------------------------------
function RunControl.bayZStart(i)
	return Config.OriginZ + (i - 1) * Config.BayPitch
end

-- Course Z (bay 1's entrance = 0) of a world position.
function RunControl.courseZ(worldZ)
	return worldZ - Config.OriginZ
end

-- FACING MATTERS. An identity-rotated CFrame looks along -Z and the course runs toward +Z, so
-- every placement is built looking down the course explicitly.
local function lookDownCourse(pos)
	return CFrame.lookAt(pos, pos + Vector3.new(0, 0, 1))
end

-- Just outside bay i's entrance, centred, so the player walks in through the doorway.
function RunControl.approachCFrame(i)
	return lookDownCourse(Vector3.new(Config.BayWidth / 2, 4, RunControl.bayZStart(i) - 4))
end

-- The course start: the map's Start part (the obby's old SpawnLocation, made a plain part so the
-- arcade never spawns anyone into the obby). Never a SpawnLocation lookup: in the arcade that finds
-- the Workshop's.
function RunControl.startCFrame()
	local s = RunControl.session
	local start = s and s.map and s.map:FindFirstChild("Start")
	if start and start:IsA("BasePart") then
		return lookDownCourse(start.Position + Vector3.new(0, start.Size.Y / 2 + 3.5, 0))
	end
	return lookDownCourse(Vector3.new(Config.BayWidth / 2, 4, Config.OriginZ - (Config.EntranceBuffer or 10) + 4))
end

-- Puts a character at cf, still. Turning the BODY does not turn the CAMERA (the default camera owns
-- its yaw on the client), so the client's CameraPolish is told which way to look.
function RunControl.placeCharacter(player, cf)
	local character = player and player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false
	end
	character:PivotTo(cf)
	hrp.AssemblyLinearVelocity = Vector3.zero
	-- When, so Module's respawn checkpoint can tell that something else (a debug command) already put
	-- this new character somewhere and leave it there.
	local s = RunControl.session
	if s and s.placedAt then
		s.placedAt[player] = os.clock()
	end
	local remotes = ReplicatedStorage.Obby:FindFirstChild("Remotes")
	local cameraFace = remotes and remotes:FindFirstChild("CameraFace")
	if cameraFace then
		cameraFace:FireClient(player, cf.LookVector)
	end
	return true
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
	ReplicatedStorage.Obby:SetAttribute("FeedMode", mode)
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
