-- ServerStorage.Modes.Obby.Server.GhostMode (ModuleScript)
-- GhostMode -- debug spectator toggle (Q). Lets you tour every bay without dying: invincible,
-- no collision, and ignored by mobs. The character attribute "Ghost" is the single source of
-- truth; HazardManager checks it before doing any damage.
--
-- ARCADE: debug only (session.debug, Config.ArcadeDebug), never shipped in a round, and only this
-- round's runners can toggle it.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunControl = require(script.Parent:WaitForChild("RunControl"))
local session = RunControl.session

local GhostMode = {}

if not session.debug then
	return GhostMode
end

local GhostToggle = ReplicatedStorage.Obby:WaitForChild("Remotes"):WaitForChild("GhostToggle")

local function applyGhost(character, on)
	character:SetAttribute("Ghost", on)

	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			-- HumanoidRootPart is invisible normally; don't reveal it
			if d.Name ~= "HumanoidRootPart" then
				d.Transparency = on and 0.6 or 0
			end
			d.CanCollide = not on
		elseif d:IsA("Decal") then
			d.Transparency = on and 0.6 or 0
		end
	end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		if on then
			hum.MaxHealth = math.huge
			hum.Health = math.huge
		else
			hum.MaxHealth = 100
			hum.Health = 100
		end
	end
end

session.track(GhostToggle.OnServerEvent:Connect(function(player)
	if not session.isRunner(player) then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local on = not (character:GetAttribute("Ghost") == true)
	applyGhost(character, on)
	print("[GhostMode] " .. player.Name .. " ghost = " .. tostring(on))
	GhostToggle:FireClient(player, on)
end))

-- a fresh character starts solid again (this round's runners only; no global PlayerAdded hook)
for _, plr in ipairs(session.runners) do
	if plr.Character then
		plr.Character:SetAttribute("Ghost", false)
	end
	session.track(plr.CharacterAdded:Connect(function(char)
		char:SetAttribute("Ghost", false)
	end))
end

-- The round is over: nobody walks back into the Workshop invincible and see-through.
function GhostMode.stop()
	for _, plr in ipairs(session.runners) do
		local character = plr.Character
		if character and character:GetAttribute("Ghost") == true then
			applyGhost(character, false)
			GhostToggle:FireClient(plr, false)
		end
	end
end

return GhostMode
