-- StarterPlayer.StarterPlayerScripts.ArmTwinClient
-- Makes the arm twin next to the LiveBoard follow the real arm on this client: the server broadcasts
-- arm angles on PatternMatch.Remotes.ArmPose and ArmTwin.Driver eases the rig toward each sample.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Driver = require(ReplicatedStorage:WaitForChild("ArmTwin"):WaitForChild("Driver"))
local armPose = ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Remotes"):WaitForChild("ArmPose")
local twin = workspace:WaitForChild("PatternCabinet"):WaitForChild("LiveBoard"):WaitForChild("ArmTwin")

Driver.attach(twin, armPose)
