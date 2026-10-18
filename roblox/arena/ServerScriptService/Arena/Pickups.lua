--!strict
-- The player's half of the loop: crystals spawn on the floor, a player grabs one into an ability
-- slot, and firing that slot sends a real effect to the real arm.
--
-- THE EFFECT LIST IS BUILT FROM `hello.effects`, NOT HARDCODED. That field is the authoritative
-- list of names the server will accept; anything else earns an `error` frame and is ignored. If
-- Python grows a seventh effect, it shows up here with no edit - themed if Theme knows it, and
-- generic `Power` blue if not.
--
-- A PICKUP FILLS A SLOT; THE PLAYER CHOOSES WHEN TO SPEND IT. That is what makes the ability bar
-- in the concept art mean something: a slot holding a picked-up debuff carries that effect's
-- colour on its border, and the player decides whether to burn it now or save it for a worse
-- moment.
--
-- WHAT COMES BACK IS NOT WHAT WAS ASKED FOR. Python clamps intensity and duration to per-effect
-- caps, so this module's request is a request. The HUD shows `state.effects[].remaining`, which is
-- the truth, and never the duration asked for here.
--
--   local pickups = Pickups.new(workspace, arena, bridge)
--   Bridge.onHello(function(h) pickups:setEffects(h.effects) end)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Theme = require(ReplicatedStorage.Arena.Theme)
local ArenaConfig = require(ReplicatedStorage.Arena.ArenaConfig)
local Remotes = require(ReplicatedStorage.Arena.Remotes)
local Icons = require(ReplicatedStorage.Arena.Icons)

local Pickups = {}
Pickups.__index = Pickups

local C = Theme.Color

function Pickups.new(parent: Instance, arena: any, bridge: any)
	local self = setmetatable({}, Pickups)
	self.parent = parent
	self.arena = arena
	self.bridge = bridge
	self.rng = Random.new()
	self.folder = Instance.new("Folder")
	self.folder.Name = "Pickups"
	self.folder.Parent = parent

	self.effects = {} :: { string }           -- from hello.effects
	self.alive = {} :: { any }                -- crystals currently on the floor
	-- player -> { held = {index -> effect}, ready = {index -> os.clock() the slot refills} }.
	-- Two tables rather than one with "cd3" string keys mixed into an array: a slot is either
	-- holding something or cooling down, and keeping those separate is what stops freeSlot and
	-- slotView from disagreeing about what an index means.
	self.slots = {} :: { [Player]: { held: { any }, ready: { number } } }
	self.running = false
	self.lastSpawn = 0

	-- Fires when a player lands a debuff, for the toast and the sound.
	self.onLanded = nil :: ((player: Player, name: string) -> ())?

	Remotes.SlotFire.OnServerEvent:Connect(function(player, index)
		self:fireSlot(player, index)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self.slots[player] = nil
	end)
	return self
end

function Pickups.setEffects(self, effects: { string }?)
	self.effects = effects or {}
	print(("[Pickups] %d effects from hello: %s")
		:format(#self.effects, table.concat(self.effects, ", ")))
end

function Pickups.slotsFor(self, player: Player): any
	local s = self.slots[player]
	if not s then
		s = { held = {}, ready = {} }
		self.slots[player] = s
	end
	return s
end

-- What the HUD shows for this player: one entry per slot, empty slots included so the bar keeps
-- its shape.
function Pickups.slotView(self, player: Player): { any }
	local slots = self:slotsFor(player)
	local view = {}
	for i = 1, ArenaConfig.ABILITY_SLOTS do
		local entry = slots.held[i]
		local until_ = slots.ready[i]
		if entry then
			view[i] = {
				name = entry.name,
				label = Theme.effectLabel(entry.name),
				color = Theme.effectColor(entry.name),
				ready = true,
			}
		elseif until_ and os.clock() < until_ then
			view[i] = { cooldown = until_ - os.clock(), ready = false }
		else
			view[i] = { ready = false }
		end
	end
	return view
end

function Pickups.freeSlot(self, player: Player): number?
	local slots = self:slotsFor(player)
	for i = 1, ArenaConfig.ABILITY_SLOTS do
		local until_ = slots.ready[i]
		if not slots.held[i] and (not until_ or os.clock() >= until_) then
			return i
		end
	end
	return nil
end

-- A floating Neon crystal in its effect's colour. Pickups are the second-brightest things on
-- screen after the hazards, which is what makes them worth crossing the arena for.
function Pickups.spawnOne(self)
	if #self.effects == 0 or not self.arena.bounds then
		return
	end
	local name = self.effects[self.rng:NextInteger(1, #self.effects)]
	local color = Theme.effectColor(name)
	local at = self.arena:randomFloorPoint(self.rng)

	local model = Instance.new("Model")
	model.Name = "Pickup_" .. name
	model.Parent = self.folder

	local crystal = Instance.new("Part")
	crystal.Name = "Crystal"
	crystal.Size = Vector3.new(3.4, 4, 3.4)
	crystal.Anchored = true
	crystal.CanCollide = false
	crystal.CanQuery = false
	crystal.CanTouch = true
	crystal.CastShadow = false
	crystal.Material = Enum.Material.Neon
	crystal.Color = color
	crystal.CFrame = CFrame.new(at)
	crystal.Parent = model
	model.PrimaryPart = crystal

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 10
	light.Brightness = 2
	light.Parent = crystal

	-- A soft glow directly under it, so a crystal is findable from across a dark floor.
	local pool = Instance.new("Part")
	pool.Name = "Glow"
	pool.Size = Vector3.new(7, 0.2, 7)
	pool.Anchored = true
	pool.CanCollide = false
	pool.CanQuery = false
	pool.CanTouch = false
	pool.CastShadow = false
	pool.Material = Enum.Material.Neon
	pool.Color = color
	pool.Transparency = 0.6
	pool.Shape = Enum.PartType.Cylinder
	pool.CFrame = CFrame.new(at.X, self.arena.floorTopY + 0.06, at.Z) * CFrame.Angles(0, 0, math.pi / 2)
	pool.Parent = model

	-- The same icon the HUD slot will show, floating over the crystal. This is what makes a pickup
	-- worth crossing the arena for: you can tell what it is before you commit to the run, and you
	-- recognise it again when it lands in your bar.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Badge"
	billboard.Size = UDim2.fromOffset(44, 44)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 4.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 220
	billboard.Parent = crystal
	Icons.draw(billboard, name, color)

	local entry = { model = model, crystal = crystal, name = name, baseY = at.Y, taken = false }

	crystal.Touched:Connect(function(hit)
		if entry.taken then
			return
		end
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if player then
			self:grant(player, entry)
		end
	end)

	table.insert(self.alive, entry)
end

function Pickups.grant(self, player: Player, entry: any)
	local index = self:freeSlot(player)
	if not index then
		return        -- every slot full: the crystal stays for someone who can carry it
	end
	entry.taken = true
	self:slotsFor(player).held[index] = { name = entry.name, at = os.clock() }
	entry.model:Destroy()
	for i, e in self.alive do
		if e == entry then
			table.remove(self.alive, i)
			break
		end
	end
end

-- Spend a slot: send the effect to the real arm.
--
-- The index is re-checked here rather than trusted, because this crosses a RemoteEvent and a
-- client can send any number it likes. The cost of trusting it is a player firing effects they
-- never picked up.
function Pickups.fireSlot(self, player: Player, index: any)
	if type(index) ~= "number" or index < 1 or index > ArenaConfig.ABILITY_SLOTS then
		return
	end
	index = math.floor(index)
	local slots = self:slotsFor(player)
	local entry = slots.held[index]
	if not entry then
		return
	end
	slots.held[index] = nil
	slots.ready[index] = os.clock() + ArenaConfig.ABILITY_COOLDOWN_S

	local req = ArenaConfig.EFFECT_REQUEST[entry.name] or { intensity = 1.0, duration = 3.0 }
	local sent = self.bridge.sendEvent(entry.name, req.intensity, req.duration)
	if not sent then
		-- The link is down. Give the slot back rather than eating the pickup: losing a power-up to
		-- a dropped socket would read as the game cheating.
		slots.held[index] = entry
		slots.ready[index] = nil
		return
	end
	if self.onLanded then
		pcall(self.onLanded, player, entry.name)
	end
end

-- Bob and turn. These are pickups, not the dragon: hard rule 2 governs the dragon's parts only,
-- and a crystal that sits perfectly still is invisible against a busy floor.
function Pickups.step(self, dt: number)
	local t = os.clock()
	for _, e in self.alive do
		if e.crystal.Parent then
			e.crystal.CFrame = CFrame.new(e.crystal.Position.X,
				e.baseY + math.sin(t * 1.6) * 1, e.crystal.Position.Z)
				* CFrame.Angles(0, t * 0.8, math.rad(12))
		end
	end

	if self.running and t - self.lastSpawn >= ArenaConfig.PICKUP_INTERVAL_S
		and #self.alive < ArenaConfig.PICKUP_MAX_ALIVE then
		self.lastSpawn = t
		self:spawnOne()
	end
end

function Pickups.start(self)
	self.running = true
	self.lastSpawn = os.clock() - ArenaConfig.PICKUP_INTERVAL_S + 2
end

function Pickups.stop(self)
	self.running = false
end

function Pickups.clear(self)
	for _, e in self.alive do
		e.model:Destroy()
	end
	table.clear(self.alive)
	table.clear(self.slots)
end

return Pickups
