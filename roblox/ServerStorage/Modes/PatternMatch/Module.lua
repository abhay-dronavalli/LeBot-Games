-- ServerStorage.Modes.PatternMatch.Module
-- Pattern Match as an arcade mode (docs/arcade-plan.md "Mode contract", docs/pattern-match-v1.md section 13).
-- The arcade (or ServerScriptService.FakeArcade in Studio) requires this at server start, calls
-- Start(players) when a portal's join window closes, waits for Finished (up to MaxDuration seconds) and
-- then calls Stop().
--   Start(players)  clones the Map into Workspace (Config.mapName, its origin at Config.mapOffset), puts
--                   the players on PatternCabinet.StartSpot facing the table, makes Pattern Match the
--                   active game (Core.GameRegistry: every client's role view switches to it) and opens
--                   the room (Idle): the attract demo plays on the boards until the player role presses
--                   the Play prompt on the cabinet (PatternCabinet.Entry.PlayPrompt), who then picks the mode.
--   the game        room -> mode select -> shift -> results (WIN at Config.winPoints or more, else LOSE),
--                   then Finished:Fire({ { player = p, won = score >= Config.winPoints }, ... }) exactly
--                   once, one entry per player passed to Start (won = false for anyone who left). If
--                   nobody presses Play within Config.roomIdleSeconds, or all of them leave, the game ends
--                   there with won = false for everyone.
--   Stop()          cancels the game loop and every thread, disconnects every connection, stops the arm
--                   broadcast, celebrations and the attract demo, clears the active game (so the clients'
--                   views exit and remove their effects: camera shots, depth of field, stick arm) and
--                   destroys the map. Start works again afterwards.
-- Roles (Core.Roles): only the player role may press Play, pick the mode, cycle tickets or spin the
-- TargetBoard; if no
-- roles are assigned at all (Role attribute nil, e.g. a place without CoreRoles), the players in this game
-- may. The robot has no character, so the arcade never passes it to Start; it watches Views.RobotView.
-- The remotes live in ReplicatedStorage.PatternMatch.Remotes and are made when this module loads.
-- Testing hook, server only: ReplicatedStorage.PatternMatch.Debug:Fire({ op = "pick", mode = "easy" /
-- "hard" }) picks the mode during mode select; { op = "endShift" } ends the running shift (Results).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PatternMatch = ReplicatedStorage:WaitForChild("PatternMatch")
local Config = require(PatternMatch.Config)
local Game = require(PatternMatch.Game)
local BoardSpinner = require(PatternMatch.BoardSpinner)
local Stick = require(ReplicatedStorage:WaitForChild("ArmTwin"):WaitForChild("Stick"))
local Core = ReplicatedStorage:WaitForChild("Core")
local StateStore = require(Core:WaitForChild("StateStore"))
local Roles = require(Core:WaitForChild("Roles"))
local GameRegistry = require(Core:WaitForChild("GameRegistry"))

local GAME_ID = "PatternMatch" -- Core.Games.PatternMatch
local ARM_HZ = 20
local ARM_START_DELAY = 1.5 -- seconds before the first arm sample: the clients' views (ArmTwinClient) connect first
local START_SPACING = 5 -- studs between players on the start spot (fits 1.5x characters)

local mapTemplate = script.Parent:WaitForChild("Map")

local Mode = {}
Mode.DisplayName = "Pattern Match"
Mode.Tip = "Call out the pattern, the robot builds it!"
Mode.WinsToUnlock = 0
Mode.Finished = Instance.new("BindableEvent")
Mode.MaxDuration = Game.maxDuration() -- seconds from Start to Finished, at most (the arcade's timeout)

local function getOrCreate(parent, className, name)
	local child = parent:FindFirstChild(name)
	if not child then
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end

local remotes = getOrCreate(PatternMatch, "Folder", "Remotes")
local patternUI = getOrCreate(remotes, "RemoteEvent", "PatternUI")          -- server -> player, spectators: HUD payload
local robotUI = getOrCreate(remotes, "RemoteEvent", "RobotUI")              -- server -> robot: Game.robotPayload
local patternRefresh = getOrCreate(remotes, "RemoteEvent", "PatternRefresh") -- any client -> server: send me the HUD now
local patternPick = getOrCreate(remotes, "RemoteEvent", "PatternPick")      -- player -> server: "easy" / "hard"
local ticketCycle = getOrCreate(remotes, "RemoteEvent", "TicketCycle")      -- player -> server: -1 / +1 through the tickets
local patternState = getOrCreate(remotes, "BindableEvent", "PatternState")  -- server only: state changes
local armPose = getOrCreate(remotes, "UnreliableRemoteEvent", "ArmPose")    -- server -> clients: arm points, 20 Hz
local debugHook = getOrCreate(PatternMatch, "BindableEvent", "Debug")       -- server only: testing

local function log(fmt, ...)
	print("[PatternMatch] " .. string.format(fmt, ...))
end

local session = nil -- the running game, nil between Stop and Start

-- Wraps a remote handler: runs it with the session only for the player role (or, with no roles assigned,
-- for a player in this game); drops and logs everyone else.
local function guard(handler, name)
	return function(player, ...)
		local s = session
		if not s then
			return
		end
		local role = Roles.of(player)
		if role == Roles.PLAYER or (role == nil and s.inGame[player]) then
			return handler(s, player, ...)
		end
		warn(string.format("[PatternMatch] %s rejected: %s is %s, not the player", name, player and player.Name or "?",
			tostring(role)))
	end
end

-- Puts each player's character on the start spot, side by side across it, facing the table.
local function placePlayers(s)
	local spot = s.cabinet:FindFirstChild("StartSpot")
	local tableTop = s.cabinet.Table.Top
	if not spot then
		return
	end
	local floorY = spot.Position.Y - spot.Size.Y / 2
	for i, p in ipairs(s.list) do
		local character = p.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid then
			local k = i - 1
			local side = (k % 2 == 0 and 1 or -1) * math.ceil(k / 2) -- 0, -1, +1, -2, +2 ...
			local x = spot.Position + spot.CFrame.RightVector * side * START_SPACING
			local height = humanoid.RigType == Enum.HumanoidRigType.R15 and humanoid.HipHeight + root.Size.Y / 2
				or root.Size.Y * 1.5 -- R6: legs as tall as the torso
			local pos = Vector3.new(x.X, floorY + height + 0.1, x.Z)
			character:PivotTo(CFrame.lookAt(pos, Vector3.new(tableTop.Position.X, pos.Y, tableTop.Position.Z)))
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end
end

-- Reports the results to the arcade, once: one entry per player passed to Start. Nobody wins a game
-- that never left the room (why "idle").
local function finish(s, score, why)
	if s.finished then
		return
	end
	s.finished = true
	local results = {}
	for _, p in ipairs(s.list) do
		table.insert(results, { player = p, won = why ~= "idle" and p.Parent ~= nil and not s.left[p] and Game.isWin(score) })
	end
	local names = {}
	for _, r in ipairs(results) do
		table.insert(names, r.player.Name .. "=" .. (r.won and "WIN" or "LOSE"))
	end
	log("finished (%s): score %d of %d to win; %s", why, score, Config.winPoints,
		#names > 0 and table.concat(names, " ") or "no players")
	Mode.Finished:Fire(results)
end

-- Marks players who left the server; ends the game when every one of them has gone.
local function checkLeavers(s)
	if s.finished or #s.list == 0 then
		return
	end
	local here = 0
	for _, p in ipairs(s.list) do
		if p.Parent == nil then
			if not s.left[p] then
				s.left[p] = true
				log("%s left the game", p.Name)
			end
		else
			here += 1
		end
	end
	if here == 0 then
		s.game:shutdown()
		finish(s, s.game.score, "everyone left")
	end
end

-- One game tick (the loop calls it every Game.TICK seconds; tests call it directly with manual = true).
function Mode.step(dt)
	local s = session
	if not s or s.finished then
		return
	end
	s.game:step(dt)
	checkLeavers(s)
	if s.prompt then
		s.prompt.Enabled = not s.finished and s.game.state == "Idle"
	end
end

-- Play was pressed in the room (the prompt's handler, after the role check; tests call it directly): the
-- attract demo stops and mode select opens for `player`. Returns true if a game started.
function Mode.play(player)
	local s = session
	if not s or s.finished or s.game.state ~= "Idle" then
		return false
	end
	s.prompt.Enabled = false
	local started = s.game:start(player)
	if started then
		log("%s pressed Play", player and player.Name or "?")
	end
	return started
end

-- players: the arcade's list of Players with characters. opts (tests only): store (a StateStore
-- stand-in), rng, manual (true: no loop or arm broadcast threads; call Mode.step). Returns the
-- session (tests look inside it).
function Mode.Start(players, opts)
	opts = opts or {}
	if session then
		Mode.Stop()
	end
	local map = mapTemplate:Clone()
	map.Name = Config.mapName
	map:PivotTo(CFrame.new(Config.mapOffset))
	map.Parent = workspace
	local cabinet = map:WaitForChild("PatternCabinet")

	local s = {
		map = map, cabinet = cabinet, list = {}, inGame = {}, left = {}, conns = {}, threads = {}, finished = false,
	}
	for _, p in ipairs(players or {}) do
		if not s.inGame[p] then
			s.inGame[p] = true
			table.insert(s.list, p)
		end
	end
	session = s

	local chooser = nil
	for _, p in ipairs(s.list) do
		if Roles.of(p) == Roles.PLAYER then
			chooser = p
			break
		end
	end
	chooser = chooser or s.list[1]

	s.game = Game.new({
		cabinet = cabinet,
		store = opts.store or StateStore,
		ui = patternUI,
		robotUi = robotUI,
		players = function()
			return Players:GetPlayers()
		end,
		roleOf = Roles.of,
		stateChanged = patternState,
		rng = opts.rng,
		onFinished = function(score, why)
			finish(s, score, why == "idle" and "idle" or "results done")
		end,
	})

	-- Click the TargetBoard to spin it 90 degrees (player role only). The LiveBoard never spins: it and
	-- the arm twin stay fixed, like the real table.
	local targetBoard = cabinet:WaitForChild("TargetBoard")
	s.spinner = BoardSpinner.new(targetBoard)
	table.insert(s.conns, s.spinner.connection)
	table.insert(s.conns, targetBoard:WaitForChild("SpinClick").MouseClick:Connect(guard(function()
		s.spinner:request()
	end, "SpinClick")))

	-- The Play prompt on the cabinet: the player role opens mode select from the room. Shown only in the room.
	s.prompt = cabinet:WaitForChild("Entry"):WaitForChild("PlayPrompt")
	table.insert(s.conns, s.prompt.Triggered:Connect(guard(function(_, player)
		Mode.play(player)
	end, "Play Pattern Match")))
	if RunService:IsRunning() then -- (Edit-mode tests can't listen on remotes)
		table.insert(s.conns, patternPick.OnServerEvent:Connect(guard(function(_, player, choice)
			s.game:pick(player, choice)
		end, "PatternPick")))
		table.insert(s.conns, ticketCycle.OnServerEvent:Connect(guard(function(_, player, dir)
			s.game:cycleTicket(player, dir)
		end, "TicketCycle")))
		table.insert(s.conns, patternRefresh.OnServerEvent:Connect(function(player)
			s.game:pushUI(player) -- read only: the payload for this player's role
		end))
	end
	table.insert(s.conns, debugHook.Event:Connect(function(cmd)
		if type(cmd) ~= "table" then
			return
		end
		if cmd.op == "pick" and s.game.state == "ModeSelect" and not s.game.picked then
			s.game:choose(cmd.mode == "hard" and "Hard" or "Easy", "Debug hook")
		elseif cmd.op == "endShift" and s.game.state == "Shift" then
			s.game.timeLeft = 0 -- Results on the next tick
		end
	end))

	-- A player who joins mid-game, or whose role changes, gets the current HUD state right away.
	local function watchRole(player)
		table.insert(s.conns, player:GetAttributeChangedSignal(Roles.ATTRIBUTE):Connect(function()
			s.game:pushUI(player)
		end))
	end
	for _, player in ipairs(Players:GetPlayers()) do
		watchRole(player)
	end
	table.insert(s.conns, Players.PlayerAdded:Connect(function(player)
		s.game:pushUI(player)
		watchRole(player)
	end))

	placePlayers(s)
	GameRegistry.setActive(GAME_ID)
	s.game:setState("Idle") -- the room: attract demo, Play prompt, Config.roomIdleSeconds to press it
	s.prompt.Enabled = true
	log("started: %d player%s in the room, %d s to press Play, %d pts to win", #s.list, #s.list == 1 and "" or "s",
		Config.roomIdleSeconds, Config.winPoints)

	if not opts.manual then
		table.insert(s.threads, task.spawn(function()
			while session == s and not s.finished do
				Mode.step(task.wait(Game.TICK))
			end
		end))
		-- The arm twin: clients draw a stick figure from these samples (Views.Player.PatternWorld.ArmTwinClient),
		-- the bridge's arm.points as world positions over the LiveBoard. Nothing goes out unless a robot is
		-- connected (link live or mock: never the core's fake arm) with fresh arm data, so otherwise the twin
		-- holds still in its folded rest pose. Not to the robot role: its view has no arm.
		local liveBoard = cabinet:WaitForChild("LiveBoard")
		table.insert(s.threads, task.spawn(function()
			task.wait(ARM_START_DELAY)
			while session == s do
				task.wait(1 / ARM_HZ)
				local store = opts.store or StateStore
				local state = store.get()
				local armAge = tonumber(state.arm_age) -- null: no arm published yet
				local status = store.status()
				if not s.game.attract.running and (status == "live" or status == "mock") and state.arm ~= nil and armAge ~= nil
					and armAge <= Config.bridgeStaleSeconds then
					local payload = Stick.payload(state.arm.points, liveBoard)
					for _, player in ipairs(Players:GetPlayers()) do
						if Roles.of(player) ~= Roles.ROBOT then
							armPose:FireClient(player, payload)
						end
					end
				end
			end
		end))
	end
	return s
end

function Mode.Stop()
	local s = session
	if not s then
		return
	end
	session = nil
	for _, thread in ipairs(s.threads) do
		if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
			task.cancel(thread)
		end
	end
	table.clear(s.threads)
	for _, connection in ipairs(s.conns) do
		connection:Disconnect()
	end
	s.game:shutdown()
	patternState:Fire({ state = "Idle" }) -- Core.StateStore's debugAutoSolve forgets the last ticket
	if GameRegistry.active() == GAME_ID then
		GameRegistry.setActive(nil) -- every client's view exits and clears its effects
	end
	s.map:Destroy()
	log("stopped")
end

return Mode
