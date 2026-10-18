-- ServerStorage.Modes.Arena.Module
-- Dragon Arena as an arcade mode (docs/arcade-plan.md "Mode contract"). The arcade requires this at
-- server start, calls Start(players) when the portal's join window closes, waits for Finished (up to
-- MaxDuration seconds) and then calls Stop(). It is Taher's standalone arena (roblox/arena/README.md)
-- with ArenaMain's wiring moved in here and everything it owned made per game:
--   Start(players)  builds the arena under one Model, workspace.DragonArena (ModelStreamingMode
--                   Persistent), centred on ArenaConfig.CENTER (0, 0, 400): clear of the lobby at the
--                   origin, Rising Flood at (400, 0, 0) and Pattern Match at (0, 0, -400). The floor
--                   comes from the robot's hello (the printed sheet), or the Letter sheet with no
--                   hello. Moves the players onto the spawn spots, makes Dragon Arena the active game
--                   (Core.GameRegistry: the robot's client shows Views.RobotView, the aerial camera),
--                   and runs one round (Rounds): intro, countdown, ROUND_SECONDS to survive, the result.
--   the game        players alive when the timer runs out win; a hit, a death or the lava eliminates.
--                   Then Finished:Fire({ { player = p, won = ... }, ... }) exactly once, one entry per
--                   player passed to Start (won = false for anyone eliminated or gone), also when
--                   everyone dies or leaves.
--   PlayerLeft(p)   the arcade's lobby pad (the part tagged "LobbyTeleporter" in the map, "Enabled"
--                   attribute true before and after the round, false during it) or the player left:
--                   won = false for them; the game ends right away if nobody is left.
--   Stop()          disconnects every connection, cancels every thread, clears the dragon's effects,
--                   puts every player's jump back, clears the active game (the views remove their
--                   client-side effects) and destroys the map. Start works again afterwards.
-- Robot data: no connection of its own. Link reads ServerStorage.Shared.StateStore and sends the
-- players' power-ups through ServerStorage.Shared.Bridge. Lighting: never touched (the arcade owns it);
-- the arena's look is made on each client by the views.
-- Roles: the robot operator is the dragon. They have no character, so the arcade never passes them to
-- Start; they watch Views.RobotView. Everything else on screen is Views.PlayerView, shown only to the
-- players in this game.
-- Testing hook, server only: ReplicatedStorage.Arena.Debug:Fire({ op = "endRound" }) runs the timer
-- out (survivors win); { op = "eliminate", name = "Player1" } eliminates that player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ArenaShared = ReplicatedStorage:WaitForChild("Arena")
local Theme = require(ArenaShared:WaitForChild("Theme"))
local ArenaConfig = require(ArenaShared:WaitForChild("ArenaConfig"))
-- Required for its side effect: on the server, requiring Remotes creates the RemoteEvents, so they
-- exist from the moment the arcade loads this mode, before any view looks for them.
require(ArenaShared:WaitForChild("Remotes"))
local GameRegistry = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("GameRegistry"))
local Roles = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Roles"))

local Tasks = require(script.Parent.Tasks)
local Link = require(script.Parent.Link)
local Mapping = require(script.Parent.Mapping)
local Arena = require(script.Parent.Arena)
local DragonArm = require(script.Parent.DragonArm)
local AttackDetect = require(script.Parent.AttackDetect)
local AttackFx = require(script.Parent.AttackFx)
local DragonEffects = require(script.Parent.DragonEffects)
local Pickups = require(script.Parent.Pickups)
local Rounds = require(script.Parent.Rounds)
local Sound = require(script.Parent.Sound)

local GAME_ID = "Arena" -- Core.Games.Arena
local MAP_NAME = "DragonArena"

local Mode = {}
Mode.DisplayName = "Dragon Arena"
Mode.Tip = "Dodge the robot dragon and survive the timer!"
Mode.WinsToUnlock = 0
Mode.Finished = Instance.new("BindableEvent")
-- Seconds from Start to Finished, at most (the arcade's timeout): the whole round plus a margin.
Mode.MaxDuration = ArenaConfig.INTRO_SECONDS + ArenaConfig.COUNTDOWN_SECONDS + ArenaConfig.ROUND_SECONDS
	+ ArenaConfig.RESULT_SECONDS + ArenaConfig.MAX_DURATION_MARGIN

local debugHook = ArenaShared:FindFirstChild("Debug")
if not debugHook then
	debugHook = Instance.new("BindableEvent")
	debugHook.Name = "Debug"
	debugHook.Parent = ArenaShared
end

local function log(fmt, ...)
	print("[Arena] " .. string.format(fmt, ...))
end

local session = nil -- the running game, nil between Stop and Start

-- Reports to the arcade, once per game. Deferred so a game that ends inside Start or inside the
-- arcade's own PlayerLeft call still reaches a listener the arcade connects right after.
local function finish(s, results)
	if s.finished then
		return
	end
	s.finished = true
	local names = {}
	for _, r in ipairs(results) do
		table.insert(names, r.player.Name .. "=" .. (r.won and "WIN" or "LOSE"))
	end
	log("finished: %s", #names > 0 and table.concat(names, " ") or "no players")
	task.defer(function()
		Mode.Finished:Fire(results)
	end)
end

-- One state frame through the dragon, its effects and attack detection. Dragon first: everything
-- after it reads where its parts ended up.
local function apply(s, frame)
	s.dragon:update(frame.arm, frame.arm_age)
	s.effects:update(frame.effects)
	s.rounds:setEffects(frame.effects)
	-- Always called, including on a stale frame. A stale arm is a harmless dragon (hard rule 5),
	-- and AttackDetect is what enforces that - it needs the frame to notice the staleness and shut
	-- down whatever was running.
	s.detect:update(frame)
end

-- Every Heartbeat: a new state frame if there is one, else, once the link has gone quiet for longer
-- than STALE_ARM_S, the last frame marked stale. (The standalone arena only heard frames, so a link
-- that died outright left a live dragon - and a burning fire cone - with nobody driving it.)
local function tick(s, dt)
	local state = Link.state()
	local now = os.clock()
	if type(state) == "table" then
		if state ~= s.lastState then
			s.lastState = state
			s.lastFrameAt = now
			s.staleSent = false
			apply(s, state)
		elseif not s.staleSent and now - s.lastFrameAt > ArenaConfig.STALE_ARM_S then
			s.staleSent = true
			local stale = table.clone(state)
			stale.arm_age = math.huge
			apply(s, stale)
		end
	end
	s.pickups:step(dt)
	s.rounds:step(dt)
end

-- The robot and the spectators have no character, so ServerScriptService.CoreRoles streams them
-- around the lobby (Player.ReplicationFocus = Workspace.RoleStreamFocus). The map itself is
-- Persistent, but the players on it are not: point those clients' streaming at the arena while it
-- runs, and put back whatever they had in Stop.
local function aimStreaming(s, player)
	local role = Roles.of(player)
	if (role == Roles.ROBOT or role == Roles.SPECTATOR) and s.foci[player] == nil and player.Parent then
		s.foci[player] = player.ReplicationFocus or false
		player.ReplicationFocus = s.focus
	end
end

local function restoreStreaming(s)
	for player, old in pairs(s.foci) do
		if player.Parent and player.ReplicationFocus == s.focus then
			player.ReplicationFocus = old or nil
		end
	end
	table.clear(s.foci)
end

-- Wires the attacks, hits and power-ups together (this was ArenaMain).
local function wire(s)
	local detect, fx, dragon, sound, rounds = s.detect, s.fx, s.dragon, s.sound, s.rounds

	detect.onSlam = function(tipMm, speed)
		fx:slam(tipMm, speed)
		sound:at("slam", Mapping.point(tipMm), 0.8)
	end
	detect.onSweepStart = function()
		fx:sweepStart()
		local head = dragon.segments[5]
		if head then
			sound:startLoop("sweep", head.core, 0.5)
		end
	end
	detect.onSweep = function(tipMm, dir)
		fx:sweep(tipMm, dir)
	end
	detect.onSweepEnd = function()
		fx:sweepEnd()
		sound:stopLoop("sweep")
	end
	detect.onFireStart = function(frac)
		fx:fireStart(frac)
		local head = dragon.segments[5]
		if head then
			sound:at("roar", head.core.Position, 0.9)
			sound:startLoop("flame", head.core, 0.6)
		end
	end
	detect.onFire = function(frac)
		fx:fire(frac)
	end
	detect.onFireEnd = function()
		fx:fireEnd()
		sound:stopLoop("flame")
	end

	-- A hit is the dragon's doing, so the round decides what it costs. AttackFx only reports it.
	fx.onHit = function(player, kind)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root then
			sound:at("eliminated", root.Position, 0.6)
		end
		rounds:eliminate(player, kind)
	end

	-- A player landed a debuff on the real arm. The toast says who and what, in the effect's own cool
	-- colour, never a warm one, because this is the players' win.
	s.pickups.onLanded = function(player, name)
		rounds:banner("DRAGON " .. Theme.effectLabel(name) .. "!", Theme.effectColor(name), 1.5, player.Name)
		sound:ui("debuff", 0.5)
	end

	rounds.onFinished = function(results)
		finish(s, results)
	end
end

-- players: the arcade's list of Players with characters.
function Mode.Start(players)
	if session then
		Mode.Stop()
	end
	local tasks = Tasks.new()
	local map = Instance.new("Model")
	map.Name = MAP_NAME
	map.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	map:SetAttribute("Center", ArenaConfig.CENTER)
	tasks:add(map)

	local s = { tasks = tasks, map = map, finished = false, lastState = nil, lastFrameAt = os.clock(), staleSent = false }
	session = s

	local hello = Link.hello()
	s.arena = Arena.new(map, tasks)
	s.arena:build(hello and hello.space) -- moves Mapping.ORIGIN: build before anything places parts

	local function inRound(player)
		return s.rounds ~= nil and s.rounds:isAlive(player)
	end
	s.dragon = DragonArm.new(map)
	s.detect = AttackDetect.new()
	s.fx = AttackFx.new(s.arena.fx, s.arena, s.dragon, tasks, inRound)
	s.effects = DragonEffects.new(s.dragon)
	s.pickups = Pickups.new(map, s.arena, Link, tasks, inRound)
	s.pickups:setEffects(hello and hello.effects)
	s.rounds = Rounds.new(s.arena, s.dragon, s.pickups, tasks)
	s.sound = Sound.new(s.arena.fx)
	wire(s)

	s.focus = Instance.new("Part")
	s.focus.Name = "StreamFocus"
	s.focus.Anchored, s.focus.CanCollide, s.focus.CanQuery, s.focus.CanTouch = true, false, false, false
	s.focus.Transparency = 1
	s.focus.Size = Vector3.one
	s.focus.Position = ArenaConfig.CENTER + Vector3.new(0, 20, 0)
	s.focus.Parent = map
	s.foci = {}

	map.Parent = workspace
	for _, player in ipairs(Players:GetPlayers()) do
		aimStreaming(s, player)
	end
	GameRegistry.setActive(GAME_ID)
	s.sound:ambience()

	tasks:connect(RunService.Heartbeat, function(dt)
		if session == s then
			tick(s, dt)
		end
	end)
	tasks:connect(Players.PlayerRemoving, function(player)
		s.foci[player] = nil
		s.rounds:playerLeft(player)
	end)
	tasks:connect(Players.PlayerAdded, function(player)
		-- CoreRoles gives a new client its role and its lobby focus first.
		tasks:delay(1, function()
			aimStreaming(s, player)
		end)
	end)
	tasks:connect(debugHook.Event, function(cmd)
		if type(cmd) ~= "table" then
			return
		end
		if cmd.op == "endRound" and s.rounds.state == "Round" then
			s.rounds.endsAt = 0 -- survivors win on the next tick
		elseif cmd.op == "eliminate" then
			local player = Players:FindFirstChild(tostring(cmd.name))
			if player and player:IsA("Player") then
				s.rounds:eliminate(player, "debug")
			end
		end
	end)

	local list = {}
	for _, p in ipairs(players or {}) do
		if typeof(p) == "Instance" and p:IsA("Player") then
			table.insert(list, p)
		end
	end
	log("started: %d player%s, link %s, floor from %s, centre %s, %d s round", #list, #list == 1 and "" or "s",
		Link.status(), hello and hello.space and "the robot's sheet" or "the default sheet",
		tostring(ArenaConfig.CENTER), ArenaConfig.ROUND_SECONDS)
	s.rounds:begin(list)
	return s
end

-- The arcade's lobby pad, or a player gone: they lose, and the game ends if nobody is left.
function Mode.PlayerLeft(player)
	local s = session
	if s and s.rounds then
		s.rounds:playerLeft(player)
	end
end

function Mode.Stop()
	local s = session
	if not s then
		return
	end
	session = nil
	-- Threads and connections first, so nothing runs against a half torn down arena.
	s.tasks.dead = true
	pcall(function()
		s.detect:stopAll()
	end)
	s.sound:stopAll()
	s.effects:clear()
	s.pickups:clear()
	s.rounds:cleanup() -- jump heights back, ArenaInGame / ArenaAlive cleared
	restoreStreaming(s)
	s.tasks:clean() -- also destroys the map
	if GameRegistry.active() == GAME_ID then
		GameRegistry.setActive(nil) -- every client's view exits and clears its effects
	end
	log("stopped")
end

return Mode
