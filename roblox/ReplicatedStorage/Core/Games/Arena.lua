-- ReplicatedStorage.Core.Games.Arena
-- Dragon Arena's GameRegistry entry. It is an arcade mode (ServerStorage.Modes.Arena): its map
-- (Workspace.DragonArena) only exists while a game runs, so it is not the lobby game; its views show
-- only while it is active. The player view keeps its HUD hidden for anyone not in the round, and the
-- robot (the dragon) gets the overhead operator view.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local views = ReplicatedStorage:WaitForChild("Arena"):WaitForChild("Views")

return {
	id = "Arena",
	name = "Dragon Arena",
	lobby = false,
	playerView = views:WaitForChild("PlayerView"),
	robotView = views:WaitForChild("RobotView"),
}
