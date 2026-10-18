-- ReplicatedStorage.Core.Games.Obby
-- Robo Obby's GameRegistry entry. It is an arcade mode (ServerStorage.Modes.Obby) that knows nothing about
-- the registry: ServerScriptService.ArcadeActiveGame makes it the active game while its bay runs (the
-- bay's Mode attribute is "Obby"). The player's screen is Obby.Views.PlayerView (the objective HUD, the
-- solo cell grid, the dark room's camera tint); the robot gets Obby.Views.RobotView, the overseer camera
-- over the active bay with the objective and run status.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local views = ReplicatedStorage:WaitForChild("Obby"):WaitForChild("Views")

return {
	id = "Obby",
	name = "Robo Obby",
	lobby = false,
	playerView = views:WaitForChild("PlayerView"),
	robotView = views:WaitForChild("RobotView"),
}
