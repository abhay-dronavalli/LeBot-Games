-- ReplicatedStorage.Core.Roles
-- Two-role play, shared by every game (docs/roles.md):
--   "player"    walks the room and plays the game on screen; the only role whose calls change game state
--   "robot"     the operator at the real arm: no character, a fully scripted camera, and only what a blind
--               operator may see (each game's RobotView)
--   "spectator" everyone after the first two: watches the player's view, read only (a projector)
-- ServerScriptService.CoreRoles assigns roles with an Assigner and stores each one in the Player attribute
-- "Role", which every client can read.
--   Roles.PLAYER / ROBOT / SPECTATOR, Roles.ATTRIBUTE = "Role"
--   Roles.of(player)            -> the player's role, or nil before one is assigned
--   Roles.guard(handler, name)  -> a RemoteEvent / prompt handler (player, ...) that drops (and logs) calls
--                                  from anyone who isn't the player role. Wrap every remote that changes
--                                  game state with it.
--   Roles.Assigner.new(opts)    -> role bookkeeping, pure (works on fake players: anything with Name,
--                                  SetAttribute and GetAttribute). opts.forced = "player" / "robot" (or nil)
--     :join(p) -> role          the forced role if it is free, else the first free of player, robot, else
--                               spectator; sets p's "Role" attribute
--     :leave(p)                 frees p's role; the next client to join fills it (spectators stay spectators)
--     :swap() -> { players }    the player and robot trade roles (either may be empty); the changed players
--     :holder(role) -> p / nil  who holds player or robot
--     :roleOf(p)

local Roles = {}
Roles.PLAYER, Roles.ROBOT, Roles.SPECTATOR = "player", "robot", "spectator"
Roles.ATTRIBUTE = "Role"
Roles.SLOTS = { Roles.PLAYER, Roles.ROBOT } -- the two single-holder roles, filled in this order

function Roles.of(player)
	if player == nil then
		return nil
	end
	return player:GetAttribute(Roles.ATTRIBUTE)
end

function Roles.guard(handler, name)
	return function(player, ...)
		local role = Roles.of(player)
		if role ~= Roles.PLAYER then
			warn(string.format("[Roles] %s rejected: %s is %s, not the player", name or "call",
				player and player.Name or "?", tostring(role)))
			return nil
		end
		return handler(player, ...)
	end
end

local Assigner = {}
Assigner.__index = Assigner
Roles.Assigner = Assigner

function Assigner.new(opts)
	opts = opts or {}
	return setmetatable({ forced = opts.forced, slots = {}, roles = {} }, Assigner)
end

local function set(self, p, role)
	self.roles[p] = role
	p:SetAttribute(Roles.ATTRIBUTE, role)
end

function Assigner:join(p)
	local role = Roles.SPECTATOR
	local forced = self.forced
	if (forced == Roles.PLAYER or forced == Roles.ROBOT) and self.slots[forced] == nil then
		role = forced
	else
		for _, slot in ipairs(Roles.SLOTS) do
			if self.slots[slot] == nil then
				role = slot
				break
			end
		end
	end
	if role ~= Roles.SPECTATOR then
		self.slots[role] = p
	end
	set(self, p, role)
	return role
end

function Assigner:leave(p)
	local role = self.roles[p]
	if role and self.slots[role] == p then
		self.slots[role] = nil
	end
	self.roles[p] = nil
end

function Assigner:swap()
	local player, robot = self.slots[Roles.PLAYER], self.slots[Roles.ROBOT]
	self.slots[Roles.PLAYER], self.slots[Roles.ROBOT] = robot, player
	local changed = {}
	if robot then
		set(self, robot, Roles.PLAYER)
		table.insert(changed, robot)
	end
	if player then
		set(self, player, Roles.ROBOT)
		table.insert(changed, player)
	end
	return changed
end

function Assigner:holder(role)
	return self.slots[role]
end

function Assigner:roleOf(p)
	return self.roles[p]
end

return Roles
