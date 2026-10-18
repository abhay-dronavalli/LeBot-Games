-- Studio location: ServerScriptService.ArcadeManager (Script)
--[[
	ArcadeManager: owns every cabinet portal, the join window, the one-game-at-a-time
	lock, Wins, the scoreboard, the DON'T PRESS button and the robot Bridge.

	A cabinet is playable when ServerStorage.Modes has a Folder with the same name
	holding a ModuleScript called Module that follows the mode contract
	(arcade-plan.md). Cabinets without one show COMING SOON.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Bridge = require(ServerStorage.Shared.Bridge)
local StateStore = require(ServerStorage.Shared.StateStore)

local Modes = ServerStorage:WaitForChild("Modes")
local workshop = workspace:WaitForChild("Workshop")
local cabinets = workshop:WaitForChild("Bays") -- each bay folder has a Mode attribute naming its ServerStorage.Modes folder
local arcadeState = ReplicatedStorage:WaitForChild("Arcade")
local fxRemote = arcadeState:WaitForChild("ArcadeFx")
local armFolder = arcadeState:WaitForChild("Arm")
local prompt = workshop.Front.EStop.Button.Prompt
local scoreRows = workshop.BackWall.Scoreboard.Board.SurfaceGui.Rows

local JOIN_TIME = 10
local GAME_TIMEOUT = 180
local DONT_PRESS_COOLDOWN = 20
local DEFAULT_UNLOCK = { Arena = 3 } -- shown even before the mode exists
local ARM_JOINTS = { "shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper" }

local returnPoints = workshop.Front.ReturnPoints:GetChildren()
table.sort(returnPoints, function(a, b)
	return a.Position.X < b.Position.X
end)

local modules = {}
local busy = false
local joinCabinet
local joined = {}
local lastPress = -math.huge
local lockedNotice = {}

------------------------------------------------------------------ wins

local function winsOf(player)
	local stats = player:FindFirstChild("leaderstats")
	local wins = stats and stats:FindFirstChild("Wins")
	return if wins then wins.Value else 0
end

local function updateScoreboard()
	local list = Players:GetPlayers()
	table.sort(list, function(a, b)
		local wa, wb = winsOf(a), winsOf(b)
		if wa ~= wb then
			return wa > wb
		end
		return a.Name < b.Name
	end)
	for i = 1, 8 do
		local row = scoreRows:FindFirstChild("Row" .. i)
		local p = list[i]
		row.PlayerName.Text = if p then p.DisplayName else "---"
		row.Wins.Text = if p then tostring(winsOf(p)) else ""
	end
end

local function onPlayerAdded(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Parent = stats
	stats.Parent = player
	wins.Changed:Connect(updateScoreboard)
	updateScoreboard()
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	onPlayerAdded(p)
end
Players.PlayerRemoving:Connect(function()
	task.defer(updateScoreboard)
end)

local function awardWins(results, played)
	local winners = {}
	for _, r in results do
		-- only players who were actually in this game can win it
		if type(r) == "table" and r.won and played[r.player] then
			winners[r.player] = true
		end
	end
	for p in played do
		if p.Parent then
			if winners[p] then
				p.leaderstats.Wins.Value += 1
			end
			fxRemote:FireClient(p, "result", winners[p] == true)
		end
	end
end

------------------------------------------------------------------ cabinets

local function setScreens(activeCabinet, activeStatus)
	for _, cab in cabinets:GetChildren() do
		if cab == activeCabinet then
			cab:SetAttribute("Status", activeStatus)
		else
			cab:SetAttribute("Status", if activeCabinet then "ARM IN USE" else "READY")
		end
	end
end

local function isLocked(cab, player)
	return winsOf(player) < (cab:GetAttribute("WinsToUnlock") or 0)
end

local function returnPlayersToArcade(players)
	for i, p in players do
		if p.Parent and p.Character then
			local point = returnPoints[(i - 1) % #returnPoints + 1]
			p.Character:PivotTo(point.CFrame + Vector3.new(0, 3, 0))
		end
	end
end

local function waitWithTimeout(event, timeout)
	local result
	local conn = event.Event:Connect(function(r)
		if result == nil then
			result = r or {}
		end
	end)
	local t0 = os.clock()
	while result == nil and os.clock() - t0 < timeout do
		task.wait(0.1)
	end
	conn:Disconnect()
	if result == nil then
		warn("[Arcade] game timed out without firing Finished")
	end
	return result or {}
end

local function runGame(cab, firstPlayer)
	local mode = modules[cab.Name]
	joinCabinet = cab
	joined = { firstPlayer }
	firstPlayer:SetAttribute("JoinedMode", cab.Name)
	prompt.Enabled = false
	arcadeState:SetAttribute("Busy", true)
	arcadeState:SetAttribute("JoinMode", cab.Name)
	arcadeState:SetAttribute("JoinTitle", mode.DisplayName)
	setScreens(cab, "STARTING")

	for t = JOIN_TIME, 1, -1 do
		arcadeState:SetAttribute("JoinCountdown", t)
		cab:SetAttribute("Countdown", t)
		task.wait(1)
	end
	joinCabinet = nil
	arcadeState:SetAttribute("JoinMode", "")

	local players, played = {}, {}
	for _, p in joined do
		p:SetAttribute("JoinedMode", nil)
		if p.Parent and p.Character then
			table.insert(players, p)
			played[p] = true
		end
	end
	joined = {}

	if #players > 0 then
		setScreens(cab, "PLAYING")
		arcadeState:SetAttribute("ActiveMode", cab.Name)
		Bridge.send({ t = "mode", name = (cab:GetAttribute("Mode") or cab.Name):lower() })

		local results = {}
		local ok, err = pcall(mode.Start, players)
		if ok then
			results = waitWithTimeout(mode.Finished, if type(mode.MaxDuration) == "number" then mode.MaxDuration else GAME_TIMEOUT)
		else
			warn("[Arcade] " .. cab.Name .. ".Start failed: " .. tostring(err))
		end

		local stopped, stopErr = pcall(mode.Stop)
		if not stopped then
			warn("[Arcade] " .. cab.Name .. ".Stop failed: " .. tostring(stopErr))
		end
		Bridge.send({ t = "mode", name = "lobby" })
		returnPlayersToArcade(players)
		awardWins(results, played)
	end

	arcadeState:SetAttribute("ActiveMode", "")
	arcadeState:SetAttribute("Busy", false)
	setScreens(nil)
	prompt.Enabled = true
	busy = false
end

for _, cab in cabinets:GetChildren() do
	local modeName = cab:GetAttribute("Mode") or cab.Name
	local folder = Modes:FindFirstChild(modeName)
	local moduleScript = folder and folder:FindFirstChild("Module")
	local mode
	if moduleScript then
		local ok, result = pcall(require, moduleScript)
		if ok and type(result) == "table" and result.Start and result.Stop and result.Finished then
			mode = result
		else
			warn("[Arcade] " .. cab.Name .. " Module doesn't follow the mode contract: " .. tostring(result))
		end
	end
	modules[cab.Name] = mode
	cab:SetAttribute("Available", mode ~= nil)
	cab:SetAttribute("WinsToUnlock", if mode then mode.WinsToUnlock or 0 else DEFAULT_UNLOCK[modeName] or 0)
	cab:SetAttribute("Status", "READY")
	cab.TipLabel.SurfaceGui.Tip.Text = if mode then (mode.Tip or "") else "COMING SOON"
end

-- A player stepped into a cabinet's portal.
local function onPortal(cab, player)
	local mode = modules[cab.Name]
	if not mode then
		return
	end
	if isLocked(cab, player) then
		if os.clock() - (lockedNotice[player] or 0) > 2 then
			lockedNotice[player] = os.clock()
			fxRemote:FireClient(player, "locked", cab:GetAttribute("WinsToUnlock") - winsOf(player))
		end
		return
	end
	if busy then
		if joinCabinet == cab and not table.find(joined, player) then
			table.insert(joined, player)
			player:SetAttribute("JoinedMode", cab.Name)
		end
		return
	end
	busy = true -- set before anything yields, so a second player returns early
	task.spawn(runGame, cab, player)
end

-- Poll the portals instead of using Touched: Touched misses players who teleport
-- in or stand still inside a portal during the join window.
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
task.spawn(function()
	while true do
		local chars = {}
		for _, p in Players:GetPlayers() do
			if p.Character then
				table.insert(chars, p.Character)
			end
		end
		overlap.FilterDescendantsInstances = chars
		for _, cab in cabinets:GetChildren() do
			local portal = cab:FindFirstChild("Portal")
			if portal and modules[cab.Name] then
				local seen = {}
				for _, hit in workspace:GetPartBoundsInBox(portal.CFrame, portal.Size + Vector3.new(0, 0, 2), overlap) do
					local player = Players:GetPlayerFromCharacter(hit.Parent)
					if player and not seen[player] then
						seen[player] = true
						onPortal(cab, player)
					end
				end
			end
		end
		task.wait(0.25)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lockedNotice[player] = nil
	local i = table.find(joined, player)
	if i then
		table.remove(joined, i)
	end
end)

------------------------------------------------------------------ DON'T PRESS

prompt.Triggered:Connect(function(player)
	if busy or os.clock() - lastPress < DONT_PRESS_COOLDOWN then
		return
	end
	lastPress = os.clock()
	Bridge.send({ t = "event", name = "earthquake", intensity = 0.5, duration = 3 })
	fxRemote:FireAllClients("quake", player.DisplayName)
end)

------------------------------------------------------------------ arm + prompt status

local lastArmPush = 0
RunService.Heartbeat:Connect(function()
	local now = os.clock()

	local cooldown = math.max(0, DONT_PRESS_COOLDOWN - (now - lastPress))
	prompt.ActionText = if cooldown > 0 then string.format("Recharging %d", math.ceil(cooldown)) else "Press"

	if now - lastArmPush < 0.05 then
		return
	end
	lastArmPush = now
	local live = StateStore.isFresh(1) and StateStore.get().arm ~= nil
	arcadeState:SetAttribute("ArmLive", live)
	if live then
		local arm = StateStore.get().arm
		for _, joint in ARM_JOINTS do
			local v = tonumber(arm[joint])
			if v then
				armFolder:SetAttribute(joint, math.round(v * 10) / 10)
			end
		end
	end
end)

arcadeState:SetAttribute("Busy", false)
arcadeState:SetAttribute("JoinMode", "")
arcadeState:SetAttribute("ActiveMode", "")
setScreens(nil)
updateScoreboard()
Bridge.start()
