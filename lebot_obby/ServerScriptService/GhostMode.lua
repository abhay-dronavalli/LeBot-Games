-- GhostMode -- debug spectator toggle (Q). Lets you tour every bay without dying: invincible,
-- no collision, and ignored by mobs. The character attribute "Ghost" is the single source of
-- truth; HazardManager checks it before doing any damage.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GhostToggle = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GhostToggle")

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

GhostToggle.OnServerEvent:Connect(function(player)
	local character = player.Character
	if not character then
		return
	end
	local on = not (character:GetAttribute("Ghost") == true)
	applyGhost(character, on)
	print("[GhostMode] " .. player.Name .. " ghost = " .. tostring(on))
	GhostToggle:FireClient(player, on)
end)

-- a fresh character starts solid again
Players.PlayerAdded:Connect(function(plr)
	plr.CharacterAdded:Connect(function(char)
		char:SetAttribute("Ghost", false)
	end)
end)
