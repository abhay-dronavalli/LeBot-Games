-- Studio location: ServerScriptService.CharacterScale (Script)
-- Makes every character bigger so players don't look tiny in the giant workshop.
-- ScaleTo also scales jump height and walk speed, so those are put back to the defaults:
-- Rising Flood is tuned around the default 7.2-stud jump and resets walk speed after each round.
-- Only the "player" role walks the room (ServerScriptService.CoreRoles): the robot and spectators have no
-- character, so anyone whose Role attribute is "robot" or "spectator" is never scaled or touched.
-- A mode can opt a player out while they play it with the player attribute NoScale = true (the obby runs
-- its runners at 1.0x and sets it on them for the round).

local Players = game:GetService("Players")

local SCALE = 1.5
local NO_CHARACTER_ROLES = { robot = true, spectator = true }

local function wantsScale(player)
	return not NO_CHARACTER_ROLES[player:GetAttribute("Role")] and player:GetAttribute("NoScale") ~= true
end

local function scaleCharacter(player, char)
	if not wantsScale(player) then
		return
	end
	-- wait for the avatar to finish loading, or its accessories would be added unscaled
	if not player:HasAppearanceLoaded() then
		local loaded = false
		local conn = player.CharacterAppearanceLoaded:Connect(function()
			loaded = true
		end)
		local t0 = os.clock()
		while not loaded and os.clock() - t0 < 5 do
			task.wait()
		end
		conn:Disconnect()
	end
	if char.Parent and player.Character == char and wantsScale(player) then
		char:ScaleTo(SCALE)
		local hum = char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = game.StarterPlayer.CharacterWalkSpeed
			hum.JumpHeight = game.StarterPlayer.CharacterJumpHeight
		end
	end
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		scaleCharacter(player, char)
	end)
end)
for _, player in Players:GetPlayers() do
	if player.Character then
		task.spawn(scaleCharacter, player, player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		scaleCharacter(player, char)
	end)
end
