-- ServerStorage.Modes.Obby.Server.Status (ModuleScript)
-- Status -- the always-on half of the old DebugMenu: what the server knows about the course, pushed
-- to the people who need it, so no client has to guess.
--
-- The debug menu used to own this, which tied the overseer's view to a debug tool: no debug
-- menu, no status, and the robot view framed nothing. In the arcade the debug menu is off for
-- anyone playing (Config.ArcadeDebug), but the runner's cell editor and the robot operator's
-- view still need it every round, so it lives here and DebugMenu only sends commands.
--
--   Remotes.Status    (server -> client) the snapshot() table below: every field the old
--                     DebugStatus payload had, plus linkOnline / runState / runEndsAt. Sent on
--                     change and on request (a client calls Remotes.Status:FireServer()).
--   Remotes.BayCells  (server -> client) (bayIndex, cellsList) whenever a bay's cells change.
--
-- Both go to this round's runners and the robot-role players (session.robots()) only, never to
-- the whole server: everyone else is in the Workshop.
--
--   Status.push(player?)  one player, or everyone above
--   Status.bumpReset()    a full reset happened (DebugMenu); see resetToken

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Obby = ReplicatedStorage:WaitForChild("Obby")
local Config = require(Obby:WaitForChild("Config"))
local RunControl = require(script.Parent:WaitForChild("RunControl"))
local BayData = require(script.Parent:WaitForChild("BayData"))
local BlockSync = require(script.Parent:WaitForChild("BlockSync"))

local session = RunControl.session

local Remotes = Obby:WaitForChild("Remotes")
local StatusRemote = Remotes:WaitForChild("Status")
local BayCells = Remotes:WaitForChild("BayCells")

local Status = {}

-- The arcade's handle on the core robot link (Shared.Bridge). Missing in a bare test place, and
-- then the link simply reads as offline.
local sharedBridge = nil
do
	local shared = ServerStorage:FindFirstChild("Shared")
	local module = shared and shared:FindFirstChild("Bridge")
	if module then
		local ok, result = pcall(require, module)
		sharedBridge = ok and result or nil
	end
end

local function linkOnline()
	if not sharedBridge then
		return false
	end
	local ok, online = pcall(sharedBridge.isOnline)
	return ok and online == true
end

-- Who hears about the course: this round's runners, and the robot operator(s).
local function audience()
	local list = table.clone(session.runners)
	for _, r in ipairs(session.robots()) do
		if not table.find(list, r) then
			table.insert(list, r)
		end
	end
	return list
end

local function isAudience(player)
	return session.isRunner(player) or table.find(session.robots(), player) ~= nil
end

-- Bumped by a full reset. Clients that hold view state of their own -- the overseer's zoom
-- and pan -- watch this rather than guessing from the bay number, which does not change when
-- you full-reset while already standing on bay 1.
local resetToken = 0

function Status.bumpReset()
	resetToken += 1
	return resetToken
end

-- Which cells currently hold a block, pushed to clients.
--
-- The overseer's mini grid cannot work this out by looking: bays 3 and 4 set VirtualCrates, so
-- there is no crate in the world to see. A separate channel from CellsUpdated, which is the
-- cell editor's own echo and only fires in solo.
--
-- The last list per bay is kept too, so a view that opens mid-round (and asks for status) gets
-- the cells already placed instead of an empty grid until the next change.
local lastCells = {}

BlockSync.CellsChanged:Connect(function(bayModel, cellsList)
	local idx = tonumber(tostring(bayModel.Name):match("Bay(%d+)"))
	if idx then
		lastCells[idx] = cellsList
		for _, p in ipairs(audience()) do
			BayCells:FireClient(p, idx, cellsList)
		end
	end
end)

if not RunControl.waitForReady(15) then
	warn("[Status] HazardManager never published its rebuild hooks; bay status will read unsolved")
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
		-- arcade additions: is the core's robot link up, and where the run clock is
		linkOnline = linkOnline(),
		runState = Obby:GetAttribute("RunState"),
		runEndsAt = Obby:GetAttribute("RunEndsAt"),
	}
end

Status.snapshot = snapshot

function Status.push(player)
	if not session.alive then
		return
	end
	local s = snapshot()
	if player then
		StatusRemote:FireClient(player, s)
	else
		for _, p in ipairs(audience()) do
			StatusRemote:FireClient(p, s)
		end
	end
end

RunControl.FeedModeChanged:Connect(function()
	Status.push()
end)

-- The tracker moves the active bay without anyone issuing a command, so the panel has to be
-- told or it shows the bay you were standing in two bays ago -- and the overseer view, which
-- reads activeBay from the same payload, would frame the wrong bay entirely.
RunControl.ActiveBayChanged:Connect(function()
	Status.push()
end)

-- A solve is also worth broadcasting: the menu greys a cleared bay and the overseer view stops
-- marking cells it no longer wants.
RunControl.BayReset:Connect(function()
	Status.push()
end)

-- Module drives the run (Ready -> Running -> Won/Lost) through these attributes; the views show it.
session.track(Obby:GetAttributeChangedSignal("RunState"):Connect(function()
	Status.push()
end))
session.track(Obby:GetAttributeChangedSignal("RunEndsAt"):Connect(function()
	Status.push()
end))

-- A fresh character (a death and the respawn checkpoint) gets a fresh copy, as the old
-- PlayerAdded hook did -- but for this round's runners only.
for _, player in ipairs(session.runners) do
	session.track(player.CharacterAdded:Connect(function()
		task.wait(0.5)
		if session.alive and player.Parent then
			Status.push(player)
		end
	end))
end

-- A client asking (a view that just opened): the status, then every bay's cells it has missed.
session.track(StatusRemote.OnServerEvent:Connect(function(player)
	if not isAudience(player) then
		return
	end
	Status.push(player)
	for idx, cellsList in pairs(lastCells) do
		BayCells:FireClient(player, idx, cellsList)
	end
end))

task.defer(Status.push)

print(("[Status] online -- %d bays, crate source: %s, robot link %s")
	:format(Config.NumBays, RunControl.feedMode, linkOnline() and "online" or "offline"))

return Status
