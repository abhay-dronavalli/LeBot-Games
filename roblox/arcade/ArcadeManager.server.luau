-- Studio location: ServerScriptService.ArcadeManager (Script)
--[[
	ArcadeManager: owns every cabinet portal, the join window, the one-game-at-a-time
	lock, Wins, the scoreboard, the DON'T PRESS button and the robot Bridge.

	A cabinet is playable when ServerStorage.Modes has a Folder with the same name
	holding a ModuleScript called Module that follows the mode contract
	(arcade-plan.md). Cabinets without one show COMING SOON.

	Any part tagged "LobbyTeleporter" in a running mode's map is a Back to Lobby pad:
	a player in the game who stands on it while its Enabled attribute is true goes
	back to the workshop, out of the game, and loses it (the mode hears about it
	through its optional PlayerLeft(player)).
]]

local CollectionService = game:GetService("CollectionService")
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

local JOIN_TIME = 5
local GAME_TIMEOUT = 180
local TELEPORTER_TAG = "LobbyTeleporter"
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
local activeGame -- { mode, played, leftEarly } while a mode runs
local switchTo -- a bay the debug switcher wants next; runGame hands over to it on the way out

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

local function awardWins(results, played, leftEarly)
	local winners = {}
	for _, r in results do
		-- only players who were actually in this game (and stayed in it) can win it
		if type(r) == "table" and r.won and played[r.player] and not leftEarly[r.player] then
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

-- Waits for the mode's Finished, at most `timeout` seconds; stops early (no results) once stopEarly() is true.
local function waitWithTimeout(event, timeout, stopEarly)
	local result
	local conn = event.Event:Connect(function(r)
		if result == nil then
			result = r or {}
		end
	end)
	local t0 = os.clock()
	local stopped = false
	while result == nil and os.clock() - t0 < timeout do
		if stopEarly and stopEarly() then
			stopped = true
			break
		end
		task.wait(0.1)
	end
	conn:Disconnect()
	if result == nil and not stopped then
		warn("[Arcade] game timed out without firing Finished")
	end
	return result or {}
end

-- A player in the running game stepped on an enabled Back to Lobby pad: out of the game, back to the workshop.
local function leaveToLobby(g, player)
	g.leftEarly[player] = true
	returnPlayersToArcade({ player })
	if g.mode.PlayerLeft then
		local ok, err = pcall(g.mode.PlayerLeft, player)
		if not ok then
			warn("[Arcade] PlayerLeft failed: " .. tostring(err))
		end
	end
end

-- Pad look: glowing green with BACK TO LOBBY when Enabled, dim with LOCKED when not.
local function styleTeleporter(pad)
	if not pad:IsA("BasePart") then
		return
	end
	local on = pad:GetAttribute("Enabled") == true
	pad.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
	pad.Color = if on then Color3.fromRGB(60, 255, 120) else Color3.fromRGB(45, 60, 50)
	local light = pad:FindFirstChild("LobbyGlow") or Instance.new("PointLight")
	light.Name = "LobbyGlow"
	light.Color = Color3.fromRGB(60, 255, 120)
	light.Range = 10
	light.Brightness = 2
	light.Enabled = on
	light.Parent = pad
	local sign = pad:FindFirstChild("LobbySign")
	if not sign then
		sign = Instance.new("BillboardGui")
		sign.Name = "LobbySign"
		sign.Size = UDim2.fromScale(7, 1.6) -- studs
		sign.StudsOffset = Vector3.new(0, 4, 0)
		sign.MaxDistance = 100
		sign.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Name = "Label"
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBlack
		label.TextScaled = true
		label.TextStrokeTransparency = 0.2
		label.Parent = sign
		sign.Parent = pad
	end
	sign.Label.Text = if on then "BACK TO LOBBY" else "LOCKED"
	sign.Label.TextColor3 = if on then Color3.fromRGB(120, 255, 160) else Color3.fromRGB(150, 150, 150)
end

local function watchTeleporter(pad)
	styleTeleporter(pad)
	pad:GetAttributeChangedSignal("Enabled"):Connect(function()
		styleTeleporter(pad)
	end)
end
CollectionService:GetInstanceAddedSignal(TELEPORTER_TAG):Connect(watchTeleporter) -- also pads in maps cloned later
for _, pad in CollectionService:GetTagged(TELEPORTER_TAG) do
	watchTeleporter(pad)
end

-- `preset`, if given, is the roster to start with immediately: the debug switcher hands the
-- players straight from one game into the next, so there is no portal to stand in and no join
-- window to sit through.
local function runGame(cab, firstPlayer, preset)
	local mode = modules[cab.Name]
	joinCabinet = if preset then nil else cab
	joined = preset or { firstPlayer }
	prompt.Enabled = false
	arcadeState:SetAttribute("Busy", true)
	arcadeState:SetAttribute("JoinTitle", mode.DisplayName)

	if preset then
		setScreens(cab, "PLAYING")
	else
		firstPlayer:SetAttribute("JoinedMode", cab.Name)
		arcadeState:SetAttribute("JoinMode", cab.Name)
		setScreens(cab, "STARTING")
		for t = JOIN_TIME, 1, -1 do
			arcadeState:SetAttribute("JoinCountdown", t)
			cab:SetAttribute("Countdown", t)
			task.wait(1)
		end
		joinCabinet = nil
		arcadeState:SetAttribute("JoinMode", "")
	end

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
		local g = { mode = mode, played = played, leftEarly = {} }
		local ok, err = pcall(mode.Start, players)
		if ok then
			activeGame = g
			results = waitWithTimeout(mode.Finished, if type(mode.MaxDuration) == "number" then mode.MaxDuration else GAME_TIMEOUT,
				function() -- the debug switcher wants another game, or everyone took a lobby pad / left
					if switchTo then
						return true
					end
					for _, p in players do
						if p.Parent and not g.leftEarly[p] then
							return false
						end
					end
					return true
				end)
			activeGame = nil
		else
			warn("[Arcade] " .. cab.Name .. ".Start failed: " .. tostring(err))
		end

		local stopped, stopErr = pcall(mode.Stop)
		if not stopped then
			warn("[Arcade] " .. cab.Name .. ".Stop failed: " .. tostring(stopErr))
		end
		local stayed = {}
		for _, p in players do
			if not g.leftEarly[p] then
				table.insert(stayed, p)
			end
		end

		-- Handing straight over to the next game. The players go from this map into that one
		-- without a stop in the workshop, `busy` is never released so no portal can race in,
		-- and nobody is awarded a win for a round that was cut off rather than played out.
		local nextCab = switchTo
		switchTo = nil
		if nextCab and modules[nextCab.Name] and #stayed > 0 then
			task.spawn(runGame, nextCab, stayed[1], stayed)
			return
		end

		Bridge.send({ t = "mode", name = "lobby" })
		returnPlayersToArcade(stayed)
		awardWins(results, played, g.leftEarly)
	end
	switchTo = nil

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
		local g = activeGame
		if g then
			for _, pad in CollectionService:GetTagged(TELEPORTER_TAG) do
				if pad:IsA("BasePart") and pad:IsDescendantOf(workspace) and pad:GetAttribute("Enabled") == true then
					for _, hit in workspace:GetPartBoundsInBox(pad.CFrame * CFrame.new(0, 3, 0), pad.Size + Vector3.new(0, 6, 0), overlap) do
						local player = Players:GetPlayerFromCharacter(hit.Parent)
						if player and g.played[player] and not g.leftEarly[player] then
							leaveToLobby(g, player)
						end
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

------------------------------------------------------------------ read the board now

-- V in any client asks the robot laptop to read the board right now. The board is normally
-- read two seconds after the gripper opens, which covers every change the *arm* makes - but a
-- cube moved by hand never opens the jaw, so the board keeps reporting where things used to
-- be until the next grab. This is the way out of that, and unlike the switcher it is not a
-- debug key: it is needed in a real demo, so it works outside Studio too.
--
-- Each read is a model call that costs money and takes a few seconds, so it is rate limited
-- here rather than trusting the client not to hold the key down.
local readBoard = Instance.new("RemoteEvent")
readBoard.Name = "ReadBoard"
readBoard.Parent = arcadeState

local READ_COOLDOWN = 4
local lastRead = -math.huge

readBoard.OnServerEvent:Connect(function(player)
	if os.clock() - lastRead < READ_COOLDOWN then
		return
	end
	lastRead = os.clock()
	local sent = Bridge.send({ t = "read_board" })
	print(string.format("[Arcade] %s asked for a board read: %s", player.Name,
		sent and "sent" or "no robot link"))
	fxRemote:FireAllClients("boardread", sent)
end)

------------------------------------------------------------------ debug: jump between games

-- Alt+1..4 in any client (ArcadeClient) jumps straight to that bay's game, ending whatever is
-- running. Studio only, like the F8 role swap: it skips the join window, the portal and the
-- unlock check, so it must never exist in a live server. The current round is abandoned rather
-- than lost - nobody is awarded a win for it either way.
local switchRemote = Instance.new("RemoteEvent")
switchRemote.Name = "ArcadeSwitch"
switchRemote.Parent = arcadeState

local function bayByNumber(n)
	for _, cab in cabinets:GetChildren() do
		if cab:GetAttribute("BayNumber") == n then
			return cab
		end
	end
	return nil
end

switchRemote.OnServerEvent:Connect(function(player, n)
	if not RunService:IsStudio() or type(n) ~= "number" then
		return -- a debug override; never in a live server
	end
	local cab = bayByNumber(n)
	if not cab then
		return
	end
	if not modules[cab.Name] then
		print(string.format("[Arcade] switch to bay %d (%s): no mode module, ignored", n, cab.Name))
		return
	end
	if busy then
		-- runGame is mid-round: ask it to wind up and hand the players over on its way out.
		switchTo = cab
		print(string.format("[Arcade] %s switched to %s", player.Name, cab.Name))
		return
	end
	-- Nothing running, so start it here, with whoever has a character, and no join window.
	local roster = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(roster, p)
		end
	end
	if #roster == 0 then
		return
	end
	busy = true
	print(string.format("[Arcade] %s started %s (debug switch)", player.Name, cab.Name))
	task.spawn(runGame, cab, roster[1], roster)
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
