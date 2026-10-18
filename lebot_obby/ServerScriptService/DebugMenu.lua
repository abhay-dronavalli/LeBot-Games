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
local DebugStatus = remote("DebugStatus")

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
		}
	end
	return {
		bays = bays,
		activeBay = RunControl.activeBay,
		feedMode = RunControl.feedMode,
		hasOverseer = RunControl.hasOverseer(),
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
		RunControl.setFeedMode(arg)
		-- Crates from the previous source belong to the previous source.
		local bay = Workspace.Warehouse:FindFirstChild(("Bay%02d"):format(RunControl.activeBay))
		if bay then
			local BlockSync = require(ServerScriptService:WaitForChild("BlockSync"))
			BlockSync.clearBay(bay)
		end
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
