-- ServerStorage.Modes.Obby.Server.BridgeFeed (ModuleScript)
-- BridgeFeed -- the live robot feed, wired into the bay (robot-link.md).
--
-- Replaces DebugMode as the source of crates in "live" feed mode. The difference is not
-- just where the data comes from: DebugMode treats a placement as a *command* and has SkyArm
-- animate a delivery, while here player 2's hands already did the delivery. So nothing is
-- animated. A cube is wherever the real cube is, and a held one follows the jaw.
--
--   hello  -> Mapping learns the real sheet geometry (never assume it; the spec is measured)
--   state  -> ArmMirror mirrors the arm, BlockSync.applyBlocks turns cubes into crates
--
-- Everything downstream of BlockSync.CellsChanged -- HazardManager's solve detection, the
-- placement guards, Bay 1's levers -- is untouched and cannot tell this from the cell editor.
--
-- THE ARCADE OWNS THE LINK. There is no obby Bridge any more: the core's ServerScriptService.Bridge
-- is the one socket, and it must never be required from here. The robot's data comes from the core
-- store instead -- ReplicatedStorage.Core.StateStore keeps the raw frame in sheet mm (get(), hello()),
-- and the arcade wrapper ServerStorage.Shared.StateStore fires Updated once per core update. Whether
-- the link is up is Shared.Bridge.isOnline(), which the Status module reports; nothing here dials,
-- hangs up or polls.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))
local RunControl = require(script.Parent:WaitForChild("RunControl"))

local Mapping = require(script.Parent:WaitForChild("Mapping"))
local ArmMirror = require(script.Parent:WaitForChild("ArmMirror"))
local BlockSync = require(script.Parent:WaitForChild("BlockSync"))
local SkyArm = require(script.Parent:WaitForChild("SkyArm"))

local session = RunControl.session

-- The core store (raw mm frames) and the arcade's Updated signal. Either may be missing in a bare
-- test place, and then there is no live feed at all -- solo still plays.
local function tryRequire(parent, ...)
	local node = parent
	for _, name in ipairs({...}) do
		node = node and node:FindFirstChild(name)
	end
	if not node then
		return nil
	end
	local ok, result = pcall(require, node)
	if not ok then
		warn("[BridgeFeed] " .. tostring(result))
		return nil
	end
	return result
end

local core = tryRequire(ReplicatedStorage, "Core", "StateStore")
local sharedStore = tryRequire(ServerStorage, "Shared", "StateStore")

-- Follows whichever bay is live. RunControl owns that, the debug menu drives it today, and
-- ActiveBayTracker drives it from the runner's position.
RunControl.setActiveBay(RunControl.activeBay)

local function currentBay()
	return RunControl.activeBayModel()
end

-- One arm on screen, and which one is a visual choice (Config.ArmStyle).
local gantry = Config.ArmStyle ~= "mirror"
local mirror = nil

-- The arm has TWO drivers and they must never overlap. In live the real arm steers it by the
-- tip; in solo the delivery job queue does, because the player is the operator and the arm is
-- carrying what they placed. Leaving live mode on in solo meant the Heartbeat kept lerping the
-- trolley toward a stale live target while a queued job tweened it somewhere else.
local function applyArmDriver()
	if gantry then
		SkyArm.setLiveMode(RunControl.feedMode == "live")
	end
end

if gantry then
	applyArmDriver()
	SkyArm.setActiveBay(RunControl.activeBayModel())
else
	mirror = ArmMirror.new(session.map)
	local ikRig = session.map:FindFirstChild("SkyArmRig")
	if ikRig then
		for _, part in ipairs(ikRig:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = 1
				part.CanCollide = false
			end
		end
	end
end

-- The crane slides along the roof to sit over whichever bay is live. This is the sliding
-- window from the plan, and it is the thing that makes one mat serve nine bays legible.
RunControl.ActiveBayChanged:Connect(function()
	if gantry then
		local bay = RunControl.activeBayModel()
		if bay then
			SkyArm.setActiveBay(bay)
		end
	end
end)

-- The hello, once per round. The core keeps the last one it got, so by the time a live round
-- starts it is already here (the link only counts as online after a hello).
local h = core and core.hello and core.hello()
if type(h) == "table" and h.space then
	Mapping.setSpace(h.space)
	RunControl.setActiveBay(RunControl.activeBay)   -- ORIGIN depends on the scale hello just set
	print(("[BridgeFeed] %s v%s, %.0f Hz | grid %dx%d @ %.2f mm | cube %.2f studs | scale %.6f")
		:format(tostring(h.source), tostring(h.v), tonumber(h.state_hz) or 0,
			Mapping.GridCols, Mapping.GridRows, Mapping.CellMm,
			Mapping.cubeStuds(), Mapping.STUDS_PER_MM))
end

-- The jaw: the frame's arm.tip when it sends one, else the point named "tip", else the last
-- point (points run base to tip).
local function tipOf(arm)
	if type(arm) ~= "table" then
		return nil
	end
	local tip = type(arm.tip) == "table" and arm.tip or nil
	if not tip and type(arm.points) == "table" then
		for _, p in ipairs(arm.points) do
			if p.name == "tip" then
				tip = p
			end
		end
		tip = tip or arm.points[#arm.points]
	end
	if not (tip and tonumber(tip.x) and tonumber(tip.y) and tonumber(tip.z)) then
		return nil
	end
	return tip
end

local function onState(s)
	-- The arm keeps following in every mode: seeing the real arm move is useful even while
	-- debugging solo, and it costs nothing. Only the CRATES are gated on being the source.
	-- Live only. In solo there is no feed at all, and the arm belongs to the job queue.
	if RunControl.feedMode ~= "live" or type(s) ~= "table" then
		return
	end

	if gantry then
		local tip = tipOf(s.arm)
		if tip then
			SkyArm.followTip(Mapping.point(tip),
				s.arm.joints and s.arm.joints.gripper or 50)
		end
	else
		mirror:update(s.arm, s.arm_age)
	end

	-- Blocks update slower than the arm (perception is ~10 Hz against the arm's 30) and both
	-- ages climb on a bus dropout or a lost sheet. A stale block pose is worse than none: it
	-- is footing the player may be standing on that is no longer where the robot thinks. Hold
	-- the last good layout rather than re-asserting a stale one.
	local age = tonumber(s.blocks_age) or 0
	if age <= (Config.StaleAfterSeconds or 2) then
		local bay = currentBay()
		if bay then
			BlockSync.applyBlocks(bay, s.blocks)
		end
	end
end

-- Every core update, read as the raw mm frame (the Shared wrapper's own state is in cm).
if core and sharedStore and sharedStore.Updated then
	session.track(sharedStore.Updated.Event:Connect(function()
		onState(core.get())
	end))
else
	warn("[BridgeFeed] no Core/Shared StateStore in this place: the live feed is off")
end

-- Crates belong to the bay they were placed in; leaving them behind on a bay change would
-- strand them in a scenario nobody is running.
RunControl.ActiveBayChanged:Connect(function(_, previous)
	local old = RunControl.bayModel(previous)
	if old then
		BlockSync.clearBay(old)
	end
end)

BlockSync.PlacementRejected:Connect(function(bayModel, cell, reason)
	-- The cube is still on player 2's real table, so this is deferred, not discarded. The live
	-- path re-checks the guard every frame, so it lands the moment the guard relents.
	print(("[BridgeFeed] placement refused at (%s,%s): %s")
		:format(tostring(cell.col), tostring(cell.row), tostring(reason or "no reason given")))
end)

-- A mode change is a hard reset. Crates placed by the other source are not ours, the arm's
-- driver changes under it, and a half-built bay from the previous mode is just confusing.
RunControl.FeedModeChanged:Connect(function(mode)
	applyArmDriver()
	if RunControl.rebuildAll then
		RunControl.rebuildAll()
	end
	-- The core's link stays up either way: it is the arcade's, not ours to dial or hang up.
	if mode == "live" then
		print("[BridgeFeed] LIVE -- the real arm owns the crates; nothing else may place one")
	else
		print("[BridgeFeed] SOLO -- you are the operator; the grid places, the arm carries")
	end
end)

return {}
