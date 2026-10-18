--!strict
-- The server <-> client channel for the arena. Required from both sides.
--
-- The server creates the RemoteEvents on first require (ServerStorage.Modes.Arena.Module requires
-- this when the arcade loads it, before any game starts); the client waits for them, so a view that
-- enters first still finds them.
--
-- Who is the dragon is not here: it is the robot role (ReplicatedStorage.Core.Roles), which has no
-- character and sees Views.RobotView. Who is in the round and still alive are Player attributes
-- ("ArenaInGame", "ArenaAlive") set by the server, because they are state a view can read whenever it
-- starts, not events it might miss.
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
	"SlotFire",     -- "spend ability slot n" (alive players in the round only; re-checked server side)
}

local Remotes = {}

local folder: Folder
if RunService:IsServer() then
	-- "Events", not "Remotes": this ModuleScript is already ReplicatedStorage.Arena.Remotes, and a
	-- Folder of the same name next to it would make FindFirstChild pick whichever came first.
	folder = ReplicatedStorage.Arena:FindFirstChild("Events") :: Folder
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Events"
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
	folder = ReplicatedStorage:WaitForChild("Arena"):WaitForChild("Events") :: Folder
end

for _, name in NAMES do
	Remotes[name] = folder:WaitForChild(name) :: RemoteEvent
end

return Remotes
