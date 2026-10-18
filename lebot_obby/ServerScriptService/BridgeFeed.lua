-- BridgeFeed -- the live robot feed, wired into the bay (robot-link.md).
--
-- Replaces DebugMode as the source of crates when Config.LiveFeed is on. The difference is not
-- just where the data comes from: DebugMode treats a placement as a *command* and has SkyArm
-- animate a delivery, while here player 2's hands already did the delivery. So nothing is
-- animated. A cube is wherever the real cube is, and a held one follows the jaw.
--
--   hello  -> Mapping learns the real sheet geometry (never assume it; the spec is measured)
--   state  -> ArmMirror mirrors the arm, BlockSync.applyBlocks turns cubes into crates
--
-- Everything downstream of BlockSync.CellsChanged -- HazardManager's solve detection, the
-- placement guards, Bay 1's levers -- is untouched and cannot tell this from the cell editor.

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local RunControl = require(ServerScriptService:WaitForChild("RunControl"))

local Mapping = require(ReplicatedStorage:WaitForChild("Mapping"))
local Bridge = require(ServerScriptService:WaitForChild("Bridge"))
local ArmMirror = require(ServerScriptService:WaitForChild("ArmMirror"))
local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))
local SkyArm = require(ServerScriptService:WaitForChild("SkyArm"))

-- Follows whichever bay is live. RunControl owns that, the debug menu drives it today, and
-- ActiveBayTracker will drive it from player 1's position -- at which point nothing here
-- changes.
Workspace:WaitForChild("Warehouse")
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
	mirror = ArmMirror.new(Workspace)
	local ikRig = Workspace:FindFirstChild("SkyArmRig")
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

local linked = false

Bridge.onHello(function(h)
	Mapping.setSpace(h.space)
	RunControl.setActiveBay(RunControl.activeBay)   -- ORIGIN depends on the scale hello just set
	print(("[BridgeFeed] %s v%s, %.0f Hz | grid %dx%d @ %.2f mm | cube %.2f studs | scale %.6f")
		:format(tostring(h.source), tostring(h.v), tonumber(h.state_hz) or 0,
			Mapping.GridCols, Mapping.GridRows, Mapping.CellMm,
			Mapping.cubeStuds(), Mapping.STUDS_PER_MM))
end)

Bridge.onState(function(s)
	linked = true
	-- The arm keeps following in every mode: seeing the real arm move is useful even while
	-- debugging solo, and it costs nothing. Only the CRATES are gated on being the source.
	-- Live only. In solo there is no feed at all, and the arm belongs to the job queue.
	if RunControl.feedMode ~= "live" then
		return
	end

	if gantry then
		local tip = s.arm and s.arm.tip
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
end)

-- Crates belong to the bay they were placed in; leaving them behind on a bay change would
-- strand them in a scenario nobody is running.
RunControl.ActiveBayChanged:Connect(function(_, previous)
	local warehouse = Workspace:FindFirstChild("Warehouse")
	local old = warehouse and warehouse:FindFirstChild(("Bay%02d"):format(previous))
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

-- Connect lazily, and only for live. Bridge retries every 2 s with a warning, so dialling a
-- socket nobody is serving -- which is every second of solo play -- would fill the output with
-- noise and make a real connection failure impossible to spot.
local dialled = false
local function dial()
	if dialled then
		return
	end
	dialled = true
	Bridge.connect(Config.BridgeUrl)
	print("[BridgeFeed] dialling the arm at " .. tostring(Config.BridgeUrl))
end

if RunControl.feedMode == "live" then
	dial()
end

-- A mode change is a hard reset. Crates placed by the other source are not ours, the arm's
-- driver changes under it, and a half-built bay from the previous mode is just confusing.
RunControl.FeedModeChanged:Connect(function(mode)
	applyArmDriver()
	if RunControl.rebuildAll then
		RunControl.rebuildAll()
	end
	if mode == "live" then
		dial()
		print("[BridgeFeed] LIVE -- the real arm owns the crates; nothing else may place one")
	else
		-- hang up: solo has no second machine in it
		dialled = false
		linked = false
		Bridge.disconnect()
		print("[BridgeFeed] SOLO -- you are the operator; the grid places, the arm carries")
	end
end)

-- Player 2 cannot act at all when the link is down, so the state has to be legible rather than
-- silent. A HUD banner belongs here once the overseer client exists.
local t, wasConnected = 0, false
RunService.Heartbeat:Connect(function(dt)
	t += dt
	if t < 2 then
		return
	end
	t = 0
	local now = Bridge.isConnected()
	if now ~= wasConnected then
		wasConnected = now
		print(now and "[BridgeFeed] CONTROLLER ONLINE" or "[BridgeFeed] CONTROLLER OFFLINE")
	end
	-- only worth saying while we are actually trying to be live
	if RunControl.feedMode == "live" and now and not linked then
		print("[BridgeFeed] connected, waiting for the first frame from the arm")
	end
end)
