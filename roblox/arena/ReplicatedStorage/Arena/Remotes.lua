--!strict
-- The server <-> client channel for the arena. Required from both sides.
--
-- The server creates the RemoteEvents on first require; the client waits for them. That ordering
-- is safe because ArenaMain requires this module before any player can have loaded, but the client
-- still uses WaitForChild rather than assuming - a client that joins during a server restart would
-- otherwise error on a missing remote and lose its HUD for the session.
--
-- The operator flag is deliberately NOT here. It is a player attribute instead, because it is set
-- the moment the player joins - before their LocalScript has had a chance to connect - and a
-- RemoteEvent fired at a client that is not listening yet is simply lost. An attribute is state
-- rather than an event: the client reads it whenever it gets around to starting, and still hears
-- about a later change.
--
-- Everything here is display or intent. No damage decision crosses this boundary: the server
-- decides who was hit (AttackFx), and the client is only told what to draw. A client that lies on
-- Fire can ask to spend a slot it does not have, which SlotFire re-checks server-side.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local NAMES = {
	-- Server -> client
	"Hud",        -- the whole HUD payload: round state, timer, survivors, chips, slots
	"Banner",     -- one-off centre text: countdown, round end, debuff toast
	"Shake",      -- camera shake for a slam: (strength 0..1, seconds)
	-- Client -> server
	"SlotFire",   -- "spend ability slot n"
}

local Remotes = {}

local folder: Folder
if RunService:IsServer() then
	folder = ReplicatedStorage.Arena:FindFirstChild("Remotes") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage.Arena
	end
	for _, name in NAMES do
		if not folder:FindFirstChild(name) then
			local r = Instance.new("RemoteEvent")
			r.Name = name
			r.Parent = folder
		end
	end
else
	folder = ReplicatedStorage:WaitForChild("Arena"):WaitForChild("Remotes") :: Folder
end

for _, name in NAMES do
	Remotes[name] = folder:WaitForChild(name) :: RemoteEvent
end

return Remotes
