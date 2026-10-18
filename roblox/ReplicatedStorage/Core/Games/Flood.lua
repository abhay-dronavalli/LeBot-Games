-- ReplicatedStorage.Core.Games.Flood
-- Rising Flood's GameRegistry entry. It is an arcade mode (ServerStorage.Modes.Flood) that knows nothing
-- about roles: ServerScriptService.ArcadeActiveGame makes it the active game while its bay runs. The
-- player's screen is FloodClient's HUD (StarterPlayerScripts), so its playerView is empty; the robot gets
-- Core.Views.FloodRobotView (the chamber from overhead and the path map).

local Views = script.Parent.Parent:WaitForChild("Views")

return {
	id = "Flood",
	name = "Sewer Surge",
	lobby = false,
	playerView = Views:WaitForChild("EmptyView"),
	robotView = Views:WaitForChild("FloodRobotView"),
}
