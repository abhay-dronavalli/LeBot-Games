-- ServerStorage.Modes.Obby.Server.DebugMenu (ModuleScript)
-- DebugMenu (server) -- jump to any scenario and start a clean run on it, solo if you like.
--
-- Separate from DebugMode on purpose. DebugMode is one *source of crates* (the cell editor
-- standing in for player 2) and stands down when the real arm owns them. This is the control
-- panel, and it has to work in every feed mode -- including "live", where DebugMode is silent.
-- Folding the two together is what left the live build with no debug menu at all.
--
-- What "a fresh run" means here, in order:
--   1. rebuild the bay's obstacle from scratch   (RunControl.rebuildBay -> HazardManager)
--   2. wipe its crates and all diff state        (BlockSync.clearBay, via the same call)
--   3. clear the objective HUD
--   4. put the player OUTSIDE the entrance, alive, at full health
--
-- Step 4 is deliberate. Teleporting *into* a bay skips the doorway, and that is exactly how
-- bay 1's entry-blocking wall survived testing: the test teleported to row 2 and never walked
-- through the door (bay-01-saw-wall.md, bug 1). The run starts on the catwalk so the entry
-- path is always exercised.
--
-- ARCADE: debug only. Module requires this only when session.debug (Config.ArcadeDebug), and
-- only this round's runners may send it commands. The status it used to broadcast (DebugStatus,
-- BayCells) is the always-on Status module now; this file just calls Status.push after a command.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunControl = require(script.Parent:WaitForChild("RunControl"))
local session = RunControl.session

if not session.debug then
	return {}
end

local Config = require(ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Config"))
local BayData = require(script.Parent:WaitForChild("BayData"))
local Status = require(script.Parent:WaitForChild("Status"))

local Remotes = ReplicatedStorage.Obby:WaitForChild("Remotes")

local DebugCommand = Remotes:WaitForChild("DebugCommand")
local GhostToggle = Remotes:WaitForChild("GhostToggle")

if not RunControl.waitForReady(15) then
	warn("[DebugMenu] HazardManager never published its rebuild hooks; menu will be inert")
end

local function pushStatus(player)
	Status.push(player)
end

----------------------------------------------------------------
-- Placement
----------------------------------------------------------------
-- Just outside the entrance, centred, so the player walks in through the doorway, facing down
-- the course: RunControl.approachCFrame (it adds Config.OriginZ and does the facing).
local function placePlayer(player, i, healFirst)
	local character = player.Character
	if not character then
		return false
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or not hum or hum.Health <= 0 then
		-- Health = MaxHealth does not revive a *destroyed* Humanoid, and a stale character
		-- reads as "no player in the bay", so the obstacle never arms and the test silently
		-- passes (bay-01-saw-wall.md, bug 2). Reload instead.
		player:LoadCharacter()
		character = player.Character or player.CharacterAdded:Wait()
		hum = character:WaitForChild("Humanoid", 5)
		hrp = character:WaitForChild("HumanoidRootPart", 5)
		if not hrp then
			return false
		end
	elseif healFirst then
		hum.Health = hum.MaxHealth
	end
	-- Turning the BODY does not turn the CAMERA: placeCharacter also tells the client's
	-- CameraPolish which way to look, or the character faces the bay and the player still sees
	-- the way they came.
	return RunControl.placeCharacter(player, RunControl.approachCFrame(i))
end

----------------------------------------------------------------
-- Commands
----------------------------------------------------------------
local ObjectiveEvent = Remotes:WaitForChild("Objective")

-- The mat maps to whichever bay is live; RunControl owns that so every crate source and
-- Mapping agree on it. ActiveBayTracker will drive the same call from player 1's position.
local function setActiveBay(i)
	return RunControl.setActiveBay(i)
end

-- The course start, not bay 1's doorway, is RunControl.startCFrame(): the map's Start part
-- (where the obby's SpawnLocation was), facing +Z. Never a SpawnLocation lookup -- in the
-- arcade that finds the Workshop's.

-- Everything back to how the place loads. Not a teleport: a FRESH CHARACTER.
--
-- A run leaves marks a teleport does not clear -- ghost mode's transparency and infinite
-- health, PlatformStand left on by the fly controller, a hazard's weld, whatever velocity you
-- died with. Those travel with the character, so the only reliable way to be rid of all of
-- them at once is to throw the character away and take a new one.
local function fullReset(player)
	setActiveBay(1)
	for i = 1, Config.NumBays do
		if RunControl.rebuildBay then
			RunControl.rebuildBay(i)       -- obstacle rebuilt + every crate wiped
		end
		task.wait()
	end

	ObjectiveEvent:FireClient(player, nil)
	player:LoadCharacter()
	local character = player.Character or player.CharacterAdded:Wait()
	if character:WaitForChild("HumanoidRootPart", 5) then
		RunControl.placeCharacter(player, RunControl.startCFrame())
	end
	-- The new character is solid, but the ghost HUD survives respawn (ResetOnSpawn = false)
	-- and would still read GHOST ON over a body that can die.
	GhostToggle:FireClient(player, false)

	print("[DebugMenu] FULL RESET -- every bay rebuilt, fresh character on the spawn")
	Status.bumpReset()
	pushStatus()
end

local function startRun(player, i)
	i = math.clamp(math.floor(i or RunControl.activeBay), 1, Config.NumBays)
	setActiveBay(i)

	if RunControl.rebuildBay then
		RunControl.rebuildBay(i)          -- obstacle from scratch + crates wiped
	end
	ObjectiveEvent:FireClient(player, nil)
	placePlayer(player, i, true)

	local info = BayData[i]
	print(("[DebugMenu] run started on Bay %02d (%s) | crate source: %s")
		:format(i, info and info.obstacle or "?", RunControl.feedMode))
	pushStatus()
end

session.track(DebugCommand.OnServerEvent:Connect(function(player, action, arg)
	if not session.isRunner(player) then
		return
	end
	if action == "teleport" then
		setActiveBay(arg)
		placePlayer(player, RunControl.activeBay, true)
		pushStatus()

	elseif action == "startRun" then
		startRun(player, arg or RunControl.activeBay)

	elseif action == "resetBay" then
		if RunControl.rebuildBay then
			RunControl.rebuildBay(RunControl.activeBay)
		end
		ObjectiveEvent:FireClient(player, nil)
		print(("[DebugMenu] Bay %02d reset in place"):format(RunControl.activeBay))
		pushStatus()

	elseif action == "fullReset" then
		fullReset(player)

	elseif action == "resetAll" then
		for i = 1, Config.NumBays do
			if RunControl.rebuildBay then
				RunControl.rebuildBay(i)
			end
			task.wait()
		end
		ObjectiveEvent:FireClient(player, nil)
		print("[DebugMenu] every bay rebuilt")
		pushStatus()

	elseif action == "feedMode" then
		-- BridgeFeed does the world reset on the change event, so every bay is rebuilt and
		-- every crate cleared -- not just the active bay's. Crates from the previous source
		-- belong to the previous source.
		RunControl.setFeedMode(arg)
		ObjectiveEvent:FireClient(player, nil)
		pushStatus()

	elseif action == "status" then
		-- the old request; Remotes.Status:FireServer() is the real one now (Status answers it)
		pushStatus(player)
	end
end))

print(("[DebugMenu] online -- %d bays, crate source: %s")
	:format(Config.NumBays, RunControl.feedMode))

return {}
