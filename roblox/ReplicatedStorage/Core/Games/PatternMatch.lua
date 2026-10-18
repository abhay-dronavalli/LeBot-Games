-- ReplicatedStorage.Core.Games.PatternMatch
-- Pattern Match's GameRegistry entry. Its player view is also the lobby's: this place's lobby is the
-- bedroom around the Pattern Match cabinet (attract demo, HUD, arm twin).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local views = ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Views")

return {
	id = "PatternMatch",
	name = "Pattern Match",
	lobby = true,
	playerView = views:WaitForChild("PlayerView"),
	robotView = views:WaitForChild("RobotView"),
}
