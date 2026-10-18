--!strict
-- The round: intro, countdown, survive the timer, win or get eaten.
--
-- Players still alive when the timer ends win. If nobody is left, the dragon wins. That is the
-- whole rule set, and everything here serves it.
--
-- As an arcade mode there is exactly one round per game, played by the players the arcade passed to
-- Start. The standalone arena looped forever (intermission, next round) and handed out characters
-- itself; here the arcade owns characters and respawns, so a round only moves the bodies it was
-- given:
--
--   Intro      players stand on the spawn spots at the front of the floor; the lobby pad is on
--   Countdown  3, 2, 1; the pad is still on (the round has not started)
--   Round      the timer runs; the pad is off; a hit, a death or leaving the floor eliminates
--   Over       the result banner; the pad is on again; then onFinished(results), once
--
-- results is the arcade's list form: one { player, won } per player passed to Start. won is true
-- only for a player still alive, still here and never left when the timer ran out.
--
-- The HUD payload is assembled in one place (`broadcast`) and pushed on a fixed tick rather than on
-- every state frame. The arm arrives at 30 Hz and the HUD does not need 30 updates a second to show
-- a timer and a survivor count. It goes only to the players in this game and to the robot and
-- spectator roles (Core.Roles), never to players waiting in the lobby.
--
-- `effects` in that payload comes straight from `state.effects` (hard rule 4), so the chips under
-- the timer count down the server's clamped remaining time, not the duration anyone asked for.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Remotes = require(ReplicatedStorage.Arena.Remotes)
local Roles = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Roles"))
local Mapping = require(script.Parent.Mapping)

-- The operator's aiming aids need to show height against the slam threshold, which is in
-- millimetres. Mapping is server-only and the views are on the client, so the converted figure
-- rides along in the payload rather than the client hardcoding a scale that would then silently
-- disagree with Mapping the first time anyone retunes it.
local SLAM_HEIGHT_STUDS = ArenaConfig.SLAM_HEIGHT_MM * Mapping.STUDS_PER_MM

-- Player attributes the views read (ReplicatedStorage.Arena.Remotes explains why attributes).
local IN_GAME = "ArenaInGame"
local ALIVE = "ArenaAlive"

local Rounds = {}
Rounds.__index = Rounds

local C = Theme.Color
local HUD_HZ = 8
local GALLERY_ROW = 6 -- spectators per row on the gallery

function Rounds.new(arena: any, dragon: any, pickups: any, tasks: any)
	local self = setmetatable({}, Rounds)
	self.arena = arena
	self.dragon = dragon
	self.pickups = pickups
	self.tasks = tasks

	self.state = "Intro"           -- Intro | Countdown | Round | Over
	self.endsAt = 0
	self.list = {} :: { Player }   -- the players passed to Start, in order
	self.inGame = {} :: { [Player]: boolean }
	self.alive = {} :: { [Player]: boolean }
	self.left = {} :: { [Player]: boolean }
	self.jump = {} :: { [Player]: { use: boolean, height: number, power: number } } -- to put back
	self.effects = {} :: { any }   -- the newest state.effects, for the HUD chips
	self.lastHud = 0
	self.done = false              -- onFinished has fired
	self.kept = {}                 -- player -> true: left after the round was over, keeps the result
	self.survivorsWon = false
	self.onFinished = nil :: ((results: { any }) -> ())?
	self.onRoundStart = nil :: (() -> ())?
	return self
end

-- ---------------------------------------------------------------------------------------------
-- Who is here
-- ---------------------------------------------------------------------------------------------

function Rounds.aliveList(self): { Player }
	local out = {}
	for _, player in self.list do
		if self.alive[player] and player.Parent then
			table.insert(out, player)
		end
	end
	return out
end

-- The players still taking part (alive or not): here, and not gone back to the lobby.
function Rounds.remaining(self): { Player }
	local out = {}
	for _, player in self.list do
		if player.Parent and not self.left[player] then
			table.insert(out, player)
		end
	end
	return out
end

function Rounds.isAlive(self, player: Player): boolean
	return self.alive[player] == true and self.state == "Round"
end

-- Who sees the HUD and the banners: the players in this game, and the robot and spectator roles.
-- Not the lobby.
function Rounds.audience(self): { Player }
	local out = {}
	for _, player in Players:GetPlayers() do
		local role = Roles.of(player)
		if (self.inGame[player] and not self.left[player]) or role == Roles.ROBOT or role == Roles.SPECTATOR then
			table.insert(out, player)
		end
	end
	return out
end

function Rounds.banner(self, text: string, color: Color3, seconds: number?, sub: string?)
	local info = { text = text, color = color, seconds = seconds or 2, sub = sub }
	for _, player in self:audience() do
		Remotes.Banner:FireClient(player, info)
	end
end

local function setAlive(self, player: Player, on: boolean)
	self.alive[player] = on or nil
	if player.Parent then
		player:SetAttribute(ALIVE, if on then true else nil)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Bodies
-- ---------------------------------------------------------------------------------------------

-- The block-scaled jump (Mapping.jumpHeight): blocks and platforms are sized to it. The arcade's
-- CharacterScale puts JumpHeight back to the default when it scales a new character, so this runs
-- on every placement, and the old values go back on in restore().
function Rounds.applyJump(self, player: Player)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if not self.jump[player] then
		self.jump[player] = { use = hum.UseJumpPower, height = hum.JumpHeight, power = hum.JumpPower }
	end
	hum.UseJumpPower = false        -- JumpHeight is ignored while UseJumpPower is true
	hum.JumpHeight = Mapping.jumpHeight(self.arena.cubeMm or 48)
end

function Rounds.restore(self, player: Player)
	local saved = self.jump[player]
	self.jump[player] = nil
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if saved and hum then
		hum.UseJumpPower = saved.use
		hum.JumpHeight = saved.height
		hum.JumpPower = saved.power
	end
	if player.Parent then
		player:SetAttribute(IN_GAME, nil)
		player:SetAttribute(ALIVE, nil)
	end
end

-- Stands a character on `at` (a point on a floor surface), feet down, facing `face`.
local function stand(char: Model, at: Vector3, face: Vector3)
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not (root and hum) then
		return
	end
	-- Feet on the surface at any character scale: R15 stands HipHeight below the root's bottom.
	local height = if hum.RigType == Enum.HumanoidRigType.R15 then hum.HipHeight + root.Size.Y / 2
		else root.Size.Y * 1.5
	local pos = at + Vector3.new(0, height + 0.2, 0)
	local look = Vector3.new(face.X, pos.Y, face.Z)
	if (look - pos).Magnitude < 0.01 then
		look = pos + Vector3.new(0, 0, -1)
	end
	char:PivotTo(CFrame.lookAt(pos, look))
	root.AssemblyLinearVelocity = Vector3.zero
end

-- Puts every player still in the game on their spawn spot, facing the dragon.
function Rounds.placeAll(self)
	local spots = self.arena:spawnPoints(#self.list)
	for i, player in self.list do
		local char = player.Character
		if char and player.Parent and not self.left[player] then
			stand(char, spots[i], self.arena:dragonEnd())
			self:applyJump(player)
		end
	end
end

function Rounds.placeOne(self, player: Player)
	local i = table.find(self.list, player) or 1
	local spots = self.arena:spawnPoints(#self.list)
	local char = player.Character
	if char then
		stand(char, spots[i], self.arena:dragonEnd())
		self:applyJump(player)
	end
end

-- The eliminated watch from the gallery, a walled ledge past the far lava: out of the dragon's
-- reach and unable to walk back onto the floor.
function Rounds.toGallery(self, player: Player)
	local char = player.Character
	if not char then
		return
	end
	local k = 0
	for _, p in self.list do
		if p == player then
			break
		end
		k += 1
	end
	local col, row = k % GALLERY_ROW, k // GALLERY_ROW
	local at = self.arena:galleryPoint(col, row, GALLERY_ROW)
	stand(char, at, self.arena:floorCentre())
end

-- A new character for a player in this game: the arcade (or Core's CoreRoles) respawned them.
function Rounds.onCharacter(self, player: Player, char: Model)
	if self.done or self.left[player] then
		return
	end
	char:WaitForChild("HumanoidRootPart", 5)
	-- LoadCharacter puts the new body on the spawn after CharacterAdded fires; a move made before
	-- that lands is undone. Let it settle in Workspace first.
	if not char:IsDescendantOf(workspace) then
		char.AncestryChanged:Wait()
	end
	task.wait(0.1)
	if self.done or self.tasks.dead or player.Character ~= char then
		return
	end
	if self.alive[player] and self.state ~= "Round" and self.state ~= "Over" then
		self:placeOne(player)
		-- CharacterScale scales a new character once its appearance loads and then resets the jump.
		self.tasks:delay(2, function()
			if player.Character == char then
				self:applyJump(player)
			end
		end)
		self.tasks:delay(5, function()
			if player.Character == char then
				self:applyJump(player)
			end
		end)
	else
		self:toGallery(player)
		-- CharacterScale resizes the body once its appearance loads: stand it on the ledge again then.
		self.tasks:delay(1.5, function()
			if not self.done and player.Character == char then
				self:toGallery(player)
			end
		end)
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		self.tasks:connect(hum.Died, function()
			if self.state == "Round" and self.alive[player] and player.Character == char then
				self:eliminate(player, "died")
			end
		end)
	end
end

-- ---------------------------------------------------------------------------------------------
-- The round
-- ---------------------------------------------------------------------------------------------

-- players: the arcade's list. Sets up the bodies and runs the round to the end on the session's
-- threads; onFinished is called once, at the end.
function Rounds.begin(self, players: { Player })
	for _, player in players do
		if not self.inGame[player] then
			self.inGame[player] = true
			table.insert(self.list, player)
			player:SetAttribute(IN_GAME, true)
			setAlive(self, player, true)
		end
	end
	for _, player in self.list do
		self.tasks:connect(player.CharacterAdded, function(char)
			self:onCharacter(player, char)
		end)
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			local char = player.Character
			self.tasks:connect(hum.Died, function()
				if self.state == "Round" and self.alive[player] and player.Character == char then
					self:eliminate(player, "died")
				end
			end)
		end
	end
	self:placeAll()
	self.arena:setPad(true)

	if #self.list == 0 then
		-- Nobody to play: the contract still wants exactly one Finished.
		self:finishNow()
		return
	end

	self.tasks:spawn(function()
		self.state = "Intro"
		self:banner("DRAGON ARENA", C.Lava, ArenaConfig.INTRO_SECONDS - 0.5, "Dodge the dragon. Survive the timer.")
		task.wait(ArenaConfig.INTRO_SECONDS)
		if self.done then
			return
		end
		self.state = "Countdown"
		for n = ArenaConfig.COUNTDOWN_SECONDS, 1, -1 do
			self:banner(tostring(n), C.UiText, 1)
			task.wait(1)
			if self.done then
				return
			end
		end
		-- The last word is Lava, the only warm colour in the round-flow text: it is the dragon's
		-- cue, not the players'.
		self:banner("SURVIVE!", C.Lava, 1.2)
		self.arena:setPad(false)
		self.state = "Round"
		self.endsAt = os.clock() + ArenaConfig.ROUND_SECONDS
		self.pickups:start()
		if self.onRoundStart then
			pcall(self.onRoundStart)
		end
		-- Anyone who died or left during the countdown is already out.
		for _, player in self.list do
			if self.alive[player] and (self.left[player] or not player.Parent) then
				setAlive(self, player, false)
			end
		end
		if #self:aliveList() == 0 then
			self:finish(false)
		end
	end)
end

-- A hit is fatal. The dragon is eight to ten times a player's height; the fantasy is dodging it,
-- not trading blows with it. Making this a health model is a design change, not a visual one.
function Rounds.eliminate(self, player: Player, cause: string)
	if self.state ~= "Round" or not self.alive[player] then
		return
	end
	setAlive(self, player, false)

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		self:emberBurst(root.Position)
	end
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		-- The default BreakJointsOnDeath does the blocky come-apart, which is the look the style
		-- guide asks for - no custom ragdoll needed. The arcade respawns them and onCharacter puts
		-- the new body in the gallery.
		hum.Health = 0
	end

	if #self:aliveList() == 0 then
		self:finish(false)
	end
end

function Rounds.emberBurst(self, at: Vector3)
	local host = Instance.new("Part")
	host.Size = Vector3.new(1, 1, 1)
	host.Transparency = 1
	host.Anchored = true
	host.CanCollide = false
	host.CanQuery = false
	host.CFrame = CFrame.new(at)
	host.Parent = self.arena.fx

	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(C.LavaHot, C.Ember)
	e.Size = NumberSequence.new(1.6, 0.2)
	e.Lifetime = NumberRange.new(0.4, 0.9)
	e.Speed = NumberRange.new(20, 48)
	e.SpreadAngle = Vector2.new(180, 180)
	e.LightEmission = 1
	e.Rate = 0
	e.Parent = host
	e:Emit(22)
	Debris:AddItem(host, 1.5)
end

function Rounds.results(self): { any }
	local out = {}
	for _, player in self.list do
		local stayed = not self.left[player] or self.kept[player] == true -- kept: left after the round was over
		local won = self.survivorsWon and self.alive[player] == true and stayed and player.Parent ~= nil
		table.insert(out, { player = player, won = won })
	end
	return out
end

-- Reports to the arcade, once.
function Rounds.finishNow(self)
	if self.done then
		return
	end
	self.done = true
	self.state = "Over"
	self.pickups:stop()
	self.arena:setPad(true)
	if self.onFinished then
		local ok, err = pcall(self.onFinished, self:results())
		if not ok then
			warn("[Arena] onFinished errored: " .. tostring(err))
		end
	end
end

-- The round is over: the result banner, then the report RESULT_SECONDS later (the contract: show
-- your own win / lose screen, then fire Finished; the arcade sends everyone back on Finished).
function Rounds.finish(self, survivorsWin: boolean)
	if self.state ~= "Round" then
		return
	end
	self.state = "Over"
	self.survivorsWon = survivorsWin
	self.pickups:stop()
	self.arena:setPad(true)

	local survivors = self:aliveList()
	if survivorsWin and #survivors > 0 then
		local names = {}
		for _, p in survivors do
			table.insert(names, p.Name)
		end
		self:banner("SURVIVORS WIN", C.Power, ArenaConfig.RESULT_SECONDS, table.concat(names, "   "))
	else
		self.survivorsWon = false
		self:banner("THE DRAGON WINS", C.Lava, ArenaConfig.RESULT_SECONDS)
		self:flareEyes()
	end
	self:broadcast()

	self.tasks:delay(ArenaConfig.RESULT_SECONDS, function()
		self:finishNow()
	end)
end

-- The dragon's eyes flare on its win. The dragon does not *move* for this (hard rule 2) - it is
-- wherever the real arm is, and a victory animation would put the visual off the hitbox.
function Rounds.flareEyes(self)
	local head = self.dragon.segments and self.dragon.segments[5]
	if not head then
		return
	end
	self.tasks:spawn(function()
		for i = 1, 24 do
			local f = 1 - i / 24
			for _, e in head.eyes do
				if e.part.Parent then
					e.part.Size = Vector3.new(1, 1, 1) * (head.spec.thickness * (0.2 + 0.3 * f))
				end
			end
			task.wait(0.08)
		end
		for _, e in head.eyes do
			if e.part.Parent then
				e.part.Size = Vector3.new(1, 1, 1) * (head.spec.thickness * 0.2)
			end
		end
	end)
end

-- A player went back to the lobby (the arcade's LobbyTeleporter, via Mode.PlayerLeft) or left the
-- server. They lose; if nobody is left in the game at all, it ends now.
function Rounds.playerLeft(self, player: Player)
	if not self.inGame[player] or self.left[player] then
		return
	end
	self.left[player] = true
	if self.state == "Over" then
		self.kept[player] = true -- the round is decided: they keep their result
	else
		setAlive(self, player, false)
	end
	self:restore(player)
	self.pickups:forget(player)
	if self.done then
		return
	end
	if #self:remaining() == 0 then
		self:finishNow()
	elseif self.state == "Round" and #self:aliveList() == 0 then
		self:finish(false)
	end
end

-- ---------------------------------------------------------------------------------------------

function Rounds.setEffects(self, effects: { any }?)
	self.effects = effects or {}
end

-- Every Heartbeat: the timer, the floor's edges and the HUD.
function Rounds.step(self, dt: number)
	if self.state == "Round" and os.clock() >= self.endsAt then
		-- The timer ran out with people still standing: they win.
		self:finish(true)
	end

	-- The lava is fatal. Nothing in the standalone arena checked it, so a player could walk out
	-- onto the moat, where the dragon was never meant to reach, and wait out the timer. Before the
	-- round, anyone who wanders off is put back instead.
	if self.state == "Round" or self.state == "Intro" or self.state == "Countdown" then
		for _, player in self:aliveList() do
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and self.arena:offFloor(root.Position) then
				if self.state == "Round" then
					self:eliminate(player, "lava")
				else
					self:placeOne(player)
				end
			end
		end
	end

	local now = os.clock()
	if now - self.lastHud >= 1 / HUD_HZ then
		self.lastHud = now
		self:broadcast()
	end
end

function Rounds.broadcast(self)
	local survivors = #self:aliveList()
	local total = #self.list

	-- Chips come from state.effects, so they show the server's clamped remaining time.
	local chips = {}
	for _, e in self.effects do
		table.insert(chips, {
			name = e.name,
			label = Theme.effectLabel(e.name),
			color = Theme.effectColor(e.name),
			remaining = e.remaining or 0,
		})
	end

	-- Who the dead are watching. One survivor for everyone rather than a per-player choice: the
	-- style guide only asks for the name under "SPECTATING".
	local watching = self:aliveList()[1]

	local base = {
		state = self.state,
		timeLeft = if self.state == "Round" then math.max(0, self.endsAt - os.clock())
			elseif self.state == "Over" then 0 else ArenaConfig.ROUND_SECONDS,
		survivors = survivors,
		total = math.max(total, survivors),
		effects = chips,
		dormant = self.dragon:isDormant(),
		slamStuds = SLAM_HEIGHT_STUDS,
	}

	-- The slot bar is per player, so the payload is finished per client rather than broadcast.
	for _, player in self:audience() do
		local payload = table.clone(base)
		payload.inGame = self.inGame[player] == true and not self.left[player]
		payload.alive = self.alive[player] == true
		if payload.inGame then
			payload.slots = self.pickups:slotView(player)
		end
		if payload.inGame and not payload.alive and watching and watching ~= player then
			payload.spectating = watching.Name
		end
		Remotes.Hud:FireClient(player, payload)
	end
end

-- Stop(): every body back to its own jump, every attribute cleared.
function Rounds.cleanup(self)
	for _, player in self.list do
		self:restore(player)
	end
	self.state = "Over"
	self.done = true
end

return Rounds
