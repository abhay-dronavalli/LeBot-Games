--!strict
-- The round: countdown, survive the timer, win or get eaten.
--
-- Players still alive when the timer ends win. If nobody is left, the dragon wins. That is the
-- whole rule set, and everything here serves it.
--
-- The HUD payload is assembled in one place (`broadcast`) and pushed to every client on a fixed
-- tick rather than on every state frame. The arm arrives at 30 Hz and the HUD does not need 30
-- updates a second to show a timer and a survivor count - and a per-frame RemoteEvent to twelve
-- clients is a real cost for no visible gain.
--
-- `effects` in that payload comes straight from `state.effects` (hard rule 4), so the chips under
-- the timer count down the server's clamped remaining time, not the duration anyone asked for.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Remotes = require(ReplicatedStorage.Arena.Remotes)

local Rounds = {}
Rounds.__index = Rounds

local C = Theme.Color
local HUD_HZ = 8

function Rounds.new(arena: any, dragon: any, pickups: any)
	local self = setmetatable({}, Rounds)
	self.arena = arena
	self.dragon = dragon
	self.pickups = pickups

	self.state = "Waiting"        -- Waiting | Countdown | Round | Over
	self.endsAt = 0
	self.alive = {} :: { [Player]: boolean }
	-- Players who never take part: the operator, who is watching from overhead and is not a
	-- survivor. Without this they count toward the survivor total and the dragon can never win.
	self.excluded = {} :: { [Player]: boolean }
	self.roundNumber = 0
	self.effects = {} :: { any }  -- the newest state.effects, for the HUD chips
	self.lastHud = 0
	self.onRoundStart = nil :: (() -> ())?
	self.onRoundEnd = nil :: ((survivors: number) -> ())?
	return self
end

function Rounds.exclude(self, player: Player)
	self.excluded[player] = true
	self.alive[player] = nil
end

function Rounds.aliveList(self): { Player }
	local out = {}
	for player, isAlive in self.alive do
		if isAlive and player.Parent then
			table.insert(out, player)
		end
	end
	return out
end

function Rounds.banner(self, text: string, color: Color3, seconds: number?, sub: string?)
	Remotes.Banner:FireAllClients({
		text = text, color = color, seconds = seconds or 2, sub = sub,
	})
end

-- ---------------------------------------------------------------------------------------------

function Rounds.start(self)
	if self.state ~= "Waiting" and self.state ~= "Over" then
		return
	end
	local players = {}
	for _, player in Players:GetPlayers() do
		if not self.excluded[player] then
			table.insert(players, player)
		end
	end
	if #players < ArenaConfig.MIN_PLAYERS then
		return
	end

	self.roundNumber += 1
	self.state = "Countdown"
	table.clear(self.alive)
	for _, player in players do
		self.alive[player] = true
		task.spawn(function()
			self:spawnInto(player)
		end)
	end

	task.spawn(function()
		for n = ArenaConfig.COUNTDOWN_SECONDS, 1, -1 do
			if self.state ~= "Countdown" then
				return
			end
			self:banner(tostring(n), C.UiText, 1)
			task.wait(1)
		end
		if self.state ~= "Countdown" then
			return
		end
		-- The last word is Lava, the only warm colour in the round-flow text: it is the dragon's
		-- cue, not the players'.
		self:banner("SURVIVE!", C.Lava, 1.2)
		self.state = "Round"
		self.endsAt = os.clock() + ArenaConfig.ROUND_SECONDS
		self.pickups:start()
		if self.onRoundStart then
			pcall(self.onRoundStart)
		end
	end)
end

-- Give the player a body and put it on the floor.
--
-- `Players.CharacterAutoLoads` is off (ArenaMain sets it), so this is the only thing that hands
-- out characters. With it on, an eliminated player respawned a few seconds later and walked back
-- into a live arena: not counted as a survivor, immune to being eliminated again because
-- `alive[player]` was already false, but still a solid body the dragon's hit tests could see.
-- Spectating is the absence of a character, which is also why `eliminate` does not reload one.
function Rounds.spawnInto(self, player: Player)
	player:LoadCharacter()
	local char = player.Character or player.CharacterAdded:Wait()
	local root = char:FindFirstChild("HumanoidRootPart")
		or char:WaitForChild("HumanoidRootPart", 5)
	if root and root:IsA("BasePart") and self.arena.bounds then
		root.CFrame = CFrame.new(self.arena:randomFloorPoint(Random.new()) + Vector3.new(0, 4, 0))
	end
end

-- A hit is fatal. The dragon is eight to ten times a player's height; the fantasy is dodging it,
-- not trading blows with it. Making this a health model is a design change, not a visual one.
function Rounds.eliminate(self, player: Player, cause: string)
	if self.state ~= "Round" or not self.alive[player] then
		return
	end
	self.alive[player] = false

	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		self:emberBurst(root.Position)
	end
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		-- The default BreakJointsOnDeath does the blocky come-apart, which is the look the style
		-- guide asks for - no custom ragdoll needed.
		hum.Health = 0
	end

	local survivors = self:aliveList()
	if #survivors == 0 then
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
	host.Parent = workspace

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

function Rounds.finish(self, survivorsWin: boolean)
	if self.state ~= "Round" then
		return
	end
	self.state = "Over"
	self.pickups:stop()

	local survivors = self:aliveList()
	if survivorsWin then
		local names = {}
		for _, p in survivors do
			table.insert(names, p.Name)
		end
		self:banner("SURVIVORS WIN", C.Power, 5, table.concat(names, "   "))
	else
		self:banner("THE DRAGON WINS", C.Lava, 5)
		self:flareEyes()
	end
	if self.onRoundEnd then
		pcall(self.onRoundEnd, #survivors)
	end

	task.delay(ArenaConfig.INTERMISSION_SECONDS, function()
		if self.state == "Over" then
			self.pickups:clear()
			self.state = "Waiting"
			self:start()
		end
	end)
end

-- The dragon's eyes flare on its win. The dragon does not *move* for this (hard rule 2) - it is
-- wherever the real arm is, and a victory animation would put the visual off the hitbox.
function Rounds.flareEyes(self)
	local head = self.dragon.segments and self.dragon.segments[5]
	if not head then
		return
	end
	task.spawn(function()
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

-- ---------------------------------------------------------------------------------------------

function Rounds.setEffects(self, effects: { any }?)
	self.effects = effects or {}
end

function Rounds.step(self, dt: number)
	if self.state == "Round" and os.clock() >= self.endsAt then
		-- The timer ran out with people still standing: they win.
		self:finish(true)
	end

	local now = os.clock()
	if now - self.lastHud >= 1 / HUD_HZ then
		self.lastHud = now
		self:broadcast()
	end
end

function Rounds.broadcast(self)
	local survivors = #self:aliveList()
	local total = 0
	for _ in self.alive do
		total += 1
	end

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
	-- style guide only asks for the name under "SPECTATING", and letting each corpse pick its own
	-- target is a camera feature nobody asked for.
	local watching = self:aliveList()[1]

	local base = {
		state = self.state,
		timeLeft = self.state == "Round" and math.max(0, self.endsAt - os.clock()) or 0,
		survivors = survivors,
		total = math.max(total, survivors),
		effects = chips,
		dormant = self.dragon:isDormant(),
	}

	-- The slot bar is per player, so the payload is finished per client rather than broadcast.
	for _, player in Players:GetPlayers() do
		local payload = table.clone(base)
		payload.slots = self.pickups:slotView(player)
		payload.alive = self.alive[player] == true
		if not payload.alive and watching and watching ~= player then
			payload.spectating = watching.Name
		end
		Remotes.Hud:FireClient(player, payload)
	end
end

function Rounds.playerAdded(self, player: Player)
	if self.excluded[player] then
		return
	end
	-- Joining mid-round means spectating until the next one: dropping someone into a live arena
	-- next to a swinging head is not a welcome. They get a body when the next round starts.
	if self.state == "Round" or self.state == "Countdown" then
		self.alive[player] = false
	else
		self.alive[player] = true
		task.spawn(function()
			self:spawnInto(player)
		end)
	end
end

function Rounds.playerRemoving(self, player: Player)
	local wasAlive = self.alive[player]
	self.alive[player] = nil
	self.excluded[player] = nil
	if wasAlive and self.state == "Round" and #self:aliveList() == 0 then
		self:finish(false)
	end
end

return Rounds
