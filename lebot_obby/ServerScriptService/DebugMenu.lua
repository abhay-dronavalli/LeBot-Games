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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

if not Config.DebugMode then
	return
end

local BayData = require(ReplicatedStorage:WaitForChild("BayData"))
local RunControl = require(ServerScriptService:WaitForChild("RunControl"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function remote(name, className)
	local r = Remotes:FindFirstChild(name)
	if not r then
		r = Instance.new(className or "RemoteEvent")
		r.Name = name
		r.Parent = Remotes
	end
	return r
end

local DebugCommand = remote("DebugCommand")
local GhostToggle = remote("GhostToggle")

-- Bumped by a full reset. Clients that hold view state of their own -- the overseer's zoom
-- and pan -- watch this rather than guessing from the bay number, which does not change when
-- you full-reset while already standing on bay 1.
local resetToken = 0
local DebugStatus = remote("DebugStatus")
local BayCells = remote("BayCells")

-- Which cells currently hold a block, pushed to clients.
--
-- The overseer's mini grid cannot work this out by looking: bays 3 and 4 set VirtualCrates, so
-- there is no crate in the world to see. A separate channel from CellsUpdated, which is the
-- debug editor's own echo and only fires in solo.
local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))
BlockSync.CellsChanged:Connect(function(bayModel, cellsList)
	local idx = tonumber(tostring(bayModel.Name):match("Bay(%d+)"))
	if idx then
		BayCells:FireAllClients(idx, cellsList)
	end
end)

if not RunControl.waitForReady(15) then
	warn("[DebugMenu] HazardManager never published its rebuild hooks; menu will be inert")
end

----------------------------------------------------------------
-- Status, so the client panel reflects the server rather than guessing
----------------------------------------------------------------
local function snapshot()
	local bays = {}
	for i = 1, Config.NumBays do
		local info = BayData[i]
		local state = RunControl.bayState and RunControl.bayState(i)
		bays[i] = {
			index = i,
			obstacle = info and info.obstacle or "?",
			color = info and info.color or nil,
			level = info and info.level or nil,
			solved = state and state.solved or false,
			switches = info and info.solveMode == "switches" or false,
			-- Where this bay wants blocks. The overseer view marks these in world, because
			-- "place a block at (1,0)" is only useful if you can see which cell that is.
			solveCells = info and info.solveCells or nil,
			banner = info and info.banner or nil,
		}
	end
	return {
		bays = bays,
		activeBay = RunControl.activeBay,
		feedMode = RunControl.feedMode,
		hasOverseer = RunControl.hasOverseer(),
		resetToken = resetToken,
	}
end

local function pushStatus(player)
	local s = snapshot()
	if player then
		DebugStatus:FireClient(player, s)
	else
		DebugStatus:FireAllClients(s)
	end
end

RunControl.FeedModeChanged:Connect(function()
	pushStatus()
end)

-- The tracker moves the active bay without anyone issuing a command, so the panel has to be
-- told or it shows the bay you were standing in two bays ago -- and the overseer view, which
-- reads activeBay from the same payload, would frame the wrong bay entirely.
RunControl.ActiveBayChanged:Connect(function()
	pushStatus()
end)

-- A solve is also worth broadcasting: the menu greys a cleared bay and the overseer view stops
-- marking cells it no longer wants.
RunControl.BayReset:Connect(function()
	pushStatus()
end)

----------------------------------------------------------------
-- Placement
----------------------------------------------------------------
-- Just outside the entrance, centred, so the player walks in through the doorway.
local function approachCFrame(i)
	local zStart = (i - 1) * Config.BayPitch
	return CFrame.new(Config.BayWidth / 2, 4, zStart - 4)
		* CFrame.Angles(0, 0, 0)
end

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
	hrp.CFrame = approachCFrame(i)
	hrp.AssemblyLinearVelocity = Vector3.zero
	return true
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

-- The course start, not bay 1's doorway. StartSpawn is where the place drops you on join,
-- so a full reset ending anywhere else is not actually "back to the beginning".
local function startCFrame()
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("SpawnLocation") then
			return d.CFrame + Vector3.new(0, 3.5, 0)
		end
	end
	return CFrame.new(Config.BayWidth / 2, 4, -(Config.EntranceBuffer or 10) + 4)
end

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
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if hrp then
		hrp.CFrame = startCFrame()
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	-- The new character is solid, but the ghost HUD survives respawn (ResetOnSpawn = false)
	-- and would still read GHOST ON over a body that can die.
	GhostToggle:FireClient(player, false)

	print("[DebugMenu] FULL RESET -- every bay rebuilt, fresh character on the spawn")
	resetToken += 1
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

DebugCommand.OnServerEvent:Connect(function(player, action, arg)
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
		pushStatus(player)
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		pushStatus(player)
	end)
end)

task.defer(pushStatus)

print(("[DebugMenu] online -- %d bays, crate source: %s")
	:format(Config.NumBays, RunControl.feedMode))
