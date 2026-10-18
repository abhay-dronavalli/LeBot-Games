-- ReplicatedStorage.Core.Games.PatternMatch
-- Pattern Match's GameRegistry entry. It is an arcade mode (ServerStorage.Modes.PatternMatch): its map
-- only exists while a game runs, so it is not the lobby game; its views show only while it is active.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local views = ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Views")

return {
	id = "PatternMatch",
	name = "Pattern Match",
	lobby = false,
	playerView = views:WaitForChild("PlayerView"),
	robotView = views:WaitForChild("RobotView"),
}
