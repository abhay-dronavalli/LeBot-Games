-- ServerStorage.Modes.Obby.Module
-- Robo Obby as an arcade mode (docs/arcade-plan.md "Mode contract", docs/obby-mode-plan.md). Kushagra's
-- course (lebot_obby/, obby_planmds/) runs here unchanged in what it asks of the player: four bays (Saw Wall,
-- Void, Laser Walk, Dark Room) that the robot operator solves with real cubes while the runner crosses them.
-- The arcade requires this at server start, calls Start(players) when the Obby bay's join window closes,
-- waits for Finished (up to MaxDuration seconds, or until everyone took a Back to Lobby pad) and then calls
-- Stop().
--   Start(players)  clones the Map into Workspace as ObbyMap (baked at Config.OriginZ, far from the other
--                   games) and the Server folder as Runtime, then requires the Runtime modules in order:
--                   fresh module state every round, so nothing from the last round can fire into this one.
--                   Feed mode for the round: "live" (the real arm owns the crates) when the core robot link
--                   is up, else "solo" (the runner places blocks on the on-screen grid). Puts the runners on
--                   Map.Start facing the course, enables the Back to Lobby pad and starts the run clock.
--   the run         reach Map.Finish (past bay 4's exit door, bay 4 solved) before the clock
--                   (Config.FullRunSeconds) runs out: won = true. A runner who dies comes back at the
--                   approach to the furthest bay they reached, rebuilt fresh. When every runner has finished
--                   or gone, or the clock hits 0, the result shows for Config.ResultSeconds and
--                   Finished:Fire({ { player = p, won = ... }, ... }) goes out exactly once, one entry per
--                   player passed to Start (won = false for anyone who left or took the pad).
--   PlayerLeft(p)   the arcade took p out through the Back to Lobby pad (Map.LobbyPad, tagged
--                   LobbyTeleporter; Enabled before the runner enters bay 1 and once the round is decided):
--                   p loses; nobody left ends the round.
--   Stop()          stops every module (their tracked connections and threads), clears the HUDs, destroys
--                   the map and the Runtime clone. Start works again afterwards.
-- The robot role has no character, so the arcade never passes it to Start: it gets Views.RobotView (the
-- overseer camera) through ReplicatedStorage.Core.Games.Obby, which ServerScriptService.ArcadeActiveGame
-- makes the active game while the bay runs. Nothing here opens a socket or touches Lighting.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local folder = script.Parent
local Obby = ReplicatedStorage:WaitForChild("Obby")
local Config = require(Obby:WaitForChild("Config"))
local mapTemplate = folder:WaitForChild("Map")
local serverTemplate = folder:WaitForChild("Server")

local Roles = nil
do
	local core = ReplicatedStorage:FindFirstChild("Core")
	local module = core and core:FindFirstChild("Roles")
	if module then
		local ok, result = pcall(require, module)
		Roles = ok and result or nil
	end
end

-- The arcade's handle on the core robot link (never a socket of our own). Missing in a bare test place.
local function sharedBridge()
	local shared = ServerStorage:FindFirstChild("Shared")
	local module = shared and shared:FindFirstChild("Bridge")
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	return ok and result or nil
end

local REMOTES = {
	"Objective", "CellEdit", "CellsUpdated", "DebugHotkey", "GhostToggle", "DebugCommand", "Status", "BayCells",
	"CameraFace",
}
-- Runtime modules in the order they are required. The former Scripts do their work at require time.
local LOAD_ORDER = { "BlockSync", "SkyArm", "HazardManager", "Status", "BridgeFeed", "DebugMode", "ActiveBayTracker" }
local DEBUG_ORDER = { "DebugMenu", "GhostMode" } -- only with Config.ArcadeDebug
local POLL = 0.25         -- seconds between finish / leaver / clock checks
local START_SPACING = 5   -- studs between runners on the start (fits 1.5x characters)
local MAP_NAME = "ObbyMap"
local LOBBY_TAG = "LobbyTeleporter"

local Mode = {}
Mode.DisplayName = "Robo Obby"
Mode.Tip = "Shout the cells, the robot builds your way through!"
Mode.WinsToUnlock = 0
Mode.Finished = Instance.new("BindableEvent")
Mode.MaxDuration = 500 -- seconds from Start to Finished, at most: the run clock (480) + result screen + slack

local function getOrCreate(parent, className, name)
	local child = parent:FindFirstChild(name)
	if not child then
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end

local remotes = getOrCreate(Obby, "Folder", "Remotes")
for _, name in ipairs(REMOTES) do
	getOrCreate(remotes, "RemoteEvent", name)
end
local objective = remotes.Objective

local function log(fmt, ...)
	print("[Obby] " .. string.format(fmt, ...))
end

local session = nil -- the running round, nil between Stop and Start

local function rootOf(player)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if hrp and hum and hum.Health > 0 then
		return hrp
	end
	return nil
end

-- Is a world position inside a part's box (any rotation)?
local function inside(part, position)
	local p = part.CFrame:PointToObjectSpace(position)
	local half = part.Size / 2
	return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
end

-- Which bay a course Z belongs to, counting the catwalk after a bay as the next one (ActiveBayTracker's rule).
local function bayAtCourseZ(z)
	if z < 0 then
		return 1
	end
	local i = math.floor(z / Config.BayPitch) + 1
	if z - (i - 1) * Config.BayPitch > Config.BayDepth then
		i += 1
	end
	return math.clamp(i, 1, Config.NumBays)
end

local function setPad(s, on)
	if s.lobbyPad then
		s.lobbyPad:SetAttribute("Enabled", on)
	end
end

local function refreshRunners(s)
	table.clear(s.runners)
	for _, p in ipairs(s.list) do
		if p.Parent ~= nil and not s.left[p] then
			table.insert(s.runners, p)
		end
	end
end

-- Shows `payload` to a player on the objective HUD, holding it there (HazardManager's bays stay off it).
local function hold(s, player, payload)
	s.hudHeld[player] = true
	objective:FireClient(player, payload)
end

-- Ends the round once: the result screen, then Finished. why: "finished" / "time" / "everyone left".
local function endRound(s, why)
	if s.done then
		return
	end
	s.done = true
	local anyWon = false
	for _, p in ipairs(s.list) do
		if s.finishedAt[p] and not s.left[p] then
			anyWon = true
		end
	end
	Obby:SetAttribute("RunState", anyWon and "Won" or "Lost")
	setPad(s, true) -- the round is decided: taking the pad now costs nothing
	s.hudHeld.all = true
	for _, p in ipairs(s.runners) do
		local won = s.finishedAt[p] ~= nil
		objective:FireClient(p, {
			title = won and "COURSE CLEAR!" or (why == "time" and "TIME'S UP" or "RUN OVER"),
			task = won and string.format("You beat the Robo Obby in %d:%02d", s.finishedAt[p] // 60, s.finishedAt[p] % 60)
				or "The course wins this time.",
			hint = "Heading back to the workshop...",
			tone = won and "ok" or "danger",
		})
	end
	for _, r in ipairs(s.robots()) do
		objective:FireClient(r, {
			title = anyWon and "COURSE CLEAR!" or (why == "time" and "TIME'S UP" or "RUN OVER"),
			task = anyWon and "Your runner made it through." or "The runner didn't make it this time.",
			hint = "Heading back to the workshop...",
			tone = anyWon and "ok" or "danger",
		})
	end
	local names = {}
	for _, p in ipairs(s.list) do
		table.insert(names, p.Name .. "=" .. ((s.finishedAt[p] and not s.left[p]) and "WIN" or "LOSE"))
	end
	log("round over (%s): %s", why, #names > 0 and table.concat(names, " ") or "no players")

	s.spawn(function()
		task.wait(Config.ResultSeconds or 4)
		if session ~= s or s.firedFinished then
			return
		end
		s.firedFinished = true
		local results = {}
		for _, p in ipairs(s.list) do
			table.insert(results, { player = p, won = s.finishedAt[p] ~= nil and not s.left[p] and p.Parent ~= nil })
		end
		Mode.Finished:Fire(results)
	end)
end

-- One check (every POLL seconds): leavers, the run starting, furthest bays, the finish, the clock.
local function tick(s)
	if s.done then
		return
	end
	refreshRunners(s)
	if #s.runners == 0 then
		endRound(s, "everyone left")
		return
	end
	local RunControl = s.RunControl
	local now = workspace:GetServerTimeNow()
	local lastBay = RunControl.bayState and RunControl.bayState(Config.NumBays)
	local allDone = true
	for _, p in ipairs(s.runners) do
		local hrp = rootOf(p)
		if hrp then
			local z = RunControl.courseZ(hrp.Position.Z)
			if s.phase == "Ready" and z >= 0 then
				-- into bay 1: the run is on, and the pad goes dark until the round is decided
				s.phase = "Running"
				Obby:SetAttribute("RunState", "Running")
				setPad(s, false)
				log("%s started the course", p.Name)
			end
			s.furthest[p] = math.max(s.furthest[p] or 1, bayAtCourseZ(z))
			if not s.finishedAt[p] and s.finish and inside(s.finish, hrp.Position) and lastBay and lastBay.solved then
				s.finishedAt[p] = math.floor(now - s.startedAt)
				log("%s reached the finish in %d s", p.Name, s.finishedAt[p])
				hold(s, p, {
					title = "COURSE CLEAR!",
					task = #s.runners > 1 and "Waiting for the others..." or "You made it!",
					tone = "ok",
				})
			end
		end
		if not s.finishedAt[p] then
			allDone = false
		end
	end
	if allDone then
		endRound(s, "finished")
	elseif now >= s.endsAt then
		endRound(s, "time")
	end
end

-- A runner's new character (they died): back to the approach of the furthest bay they reached, that bay
-- rebuilt fresh so a sealed gate or a half-closed saw wall can't lock them out.
local function onRespawn(s, player)
	local respawnedAt = os.clock()
	task.wait(Config.RespawnSettleSeconds or 0.6) -- the arcade's CharacterScale resizes the new character first
	if session ~= s or s.done or s.left[player] or not rootOf(player) then
		return
	end
	if (s.placedAt[player] or -math.huge) >= respawnedAt then
		return -- a debug command (LoadCharacter + teleport) already placed this character
	end
	local RunControl = s.RunControl
	local i = s.furthest[player] or 1
	if s.phase == "Ready" then
		RunControl.placeCharacter(player, RunControl.startCFrame())
		return
	end
	-- Rebuild only if no other living runner is in that bay right now (it would reset under their feet).
	local busy = false
	for _, other in ipairs(s.runners) do
		local hrp = other ~= player and rootOf(other)
		if hrp and bayAtCourseZ(RunControl.courseZ(hrp.Position.Z)) == i then
			busy = true
		end
	end
	if not busy and RunControl.rebuildBay then
		RunControl.rebuildBay(i)
	end
	RunControl.placeCharacter(player, RunControl.approachCFrame(i))
	log("%s respawned at bay %d%s", player.Name, i, busy and " (bay kept: another runner is in it)" or "")
end

-- players: the arcade's list of Players with characters.
function Mode.Start(players)
	if session then
		Mode.Stop()
	end
	local debug = Config.ArcadeDebug == true or folder:GetAttribute("ArcadeDebug") == true

	local map = mapTemplate:Clone()
	map.Name = MAP_NAME
	map.Parent = workspace
	local runtime = serverTemplate:Clone()
	runtime.Name = "Runtime"
	runtime.Parent = folder -- parented before requiring: the modules find their siblings through script.Parent

	local s = {
		map = map, warehouse = map:WaitForChild("Warehouse"), runtime = runtime, debug = debug,
		list = {}, inGame = {}, left = {}, runners = {}, finishedAt = {}, furthest = {}, hudHeld = {}, placedAt = {},
		conns = {}, threads = {}, modules = {}, alive = true, done = false, phase = "Ready",
	}
	function s.track(connection)
		table.insert(s.conns, connection)
		return connection
	end
	function s.spawn(fn, ...)
		local thread = task.spawn(fn, ...)
		table.insert(s.threads, thread)
		return thread
	end
	function s.isRunner(player)
		return table.find(s.runners, player) ~= nil
	end
	function s.robots()
		local list = {}
		if Roles then
			for _, p in ipairs(Players:GetPlayers()) do
				if Roles.of(p) == Roles.ROBOT then
					table.insert(list, p)
				end
			end
		end
		return list
	end
	for _, p in ipairs(players or {}) do
		if not s.inGame[p] then
			s.inGame[p] = true
			table.insert(s.list, p)
		end
	end
	refreshRunners(s)
	session = s

	s.finish = map:FindFirstChild("Finish")
	s.lobbyPad = map:FindFirstChild("LobbyPad")
	if s.lobbyPad and not CollectionService:HasTag(s.lobbyPad, LOBBY_TAG) then
		CollectionService:AddTag(s.lobbyPad, LOBBY_TAG)
	end
	if not s.finish then
		warn("[Obby] Map.Finish is missing: nobody can win this round (see docs/obby-mode-plan.md)")
	end

	local bridge = sharedBridge()
	local feedMode = (bridge and bridge.isOnline()) and "live" or "solo"
	Obby:SetAttribute("ArcadeDebug", debug)
	Obby:SetAttribute("FeedMode", feedMode)
	Obby:SetAttribute("RunSeconds", Config.FullRunSeconds)
	Obby:SetAttribute("RunState", "Ready")
	s.startedAt = workspace:GetServerTimeNow()
	s.endsAt = s.startedAt + Config.FullRunSeconds
	Obby:SetAttribute("RunEndsAt", s.endsAt)

	local RunControl = require(runtime:WaitForChild("RunControl"))
	s.RunControl = RunControl
	RunControl.session = s
	RunControl.feedMode = feedMode
	RunControl.setActiveBay(1)
	for _, name in ipairs(LOAD_ORDER) do
		s.modules[name] = require(runtime:WaitForChild(name))
	end
	if debug then
		for _, name in ipairs(DEBUG_ORDER) do
			s.modules[name] = require(runtime:WaitForChild(name))
		end
	end

	-- The runners on the start, side by side across it, facing down the course.
	local start = RunControl.startCFrame()
	for i, p in ipairs(s.runners) do
		local k = i - 1
		local side = (k % 2 == 0 and 1 or -1) * math.ceil(k / 2) -- 0, -1, +1, -2, +2 ...
		RunControl.placeCharacter(p, start + start.RightVector * side * START_SPACING)
		s.track(p.CharacterAdded:Connect(function()
			s.spawn(onRespawn, s, p)
		end))
	end
	setPad(s, true)

	s.spawn(function()
		while session == s and s.alive and not s.done do
			task.wait(POLL)
			if session == s and s.alive then
				tick(s)
			end
		end
	end)
	log("started: %d runner%s, %s mode, %d s on the clock%s", #s.runners, #s.runners == 1 and "" or "s", feedMode,
		Config.FullRunSeconds, debug and ", ARCADE DEBUG ON" or "")
	return s
end

-- The arcade took `player` out through the Back to Lobby pad: they lose, and the round ends when every
-- runner has left or gone.
function Mode.PlayerLeft(player)
	local s = session
	if not s or not s.inGame[player] or s.left[player] then
		return
	end
	s.left[player] = true
	s.hudHeld[player] = true
	objective:FireClient(player, nil)
	refreshRunners(s)
	log("%s went back to the lobby", player.Name)
	if #s.runners == 0 then
		endRound(s, "everyone left")
	end
end

function Mode.Stop()
	local s = session
	if not s then
		return
	end
	session = nil
	s.alive = false
	s.hudHeld.all = true
	for name, module in pairs(s.modules) do
		if type(module) == "table" and type(module.stop) == "function" then
			local ok, err = pcall(module.stop)
			if not ok then
				warn("[Obby] " .. name .. ".stop failed: " .. tostring(err))
			end
		end
	end
	for _, connection in ipairs(s.conns) do
		connection:Disconnect()
	end
	table.clear(s.conns)
	for _, thread in ipairs(s.threads) do
		if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
			task.cancel(thread)
		end
	end
	table.clear(s.threads)
	for _, p in ipairs(s.list) do
		if p.Parent then
			objective:FireClient(p, nil)
		end
	end
	for _, r in ipairs(s.robots()) do
		objective:FireClient(r, nil)
	end
	if s.RunControl then
		s.RunControl.session = nil
	end
	for _, name in ipairs({ "RunState", "RunEndsAt", "FeedMode" }) do
		Obby:SetAttribute(name, nil)
	end
	s.map:Destroy()
	s.runtime:Destroy()
	log("stopped")
end

return Mode
