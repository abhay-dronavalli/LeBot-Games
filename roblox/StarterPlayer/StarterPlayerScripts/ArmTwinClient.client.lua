-- StarterPlayer.StarterPlayerScripts.ArmTwinClient
-- Makes the arm twin next to the LiveBoard follow the real arm on this client: the server broadcasts
-- arm angles on PatternMatch.Remotes.ArmPose and ArmTwin.Driver eases the rig toward each sample.
-- With no arm data (before the first sample, an empty sample, or none for Driver.STALE_SECONDS) the
-- twin settles into the folded Config.twinRestPose; joints a sample leaves out take their rest values.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Driver = require(ReplicatedStorage:WaitForChild("ArmTwin"):WaitForChild("Driver"))
local armPose = ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Remotes"):WaitForChild("ArmPose")
local twin = workspace:WaitForChild("PatternCabinet"):WaitForChild("LiveBoard"):WaitForChild("ArmTwin")

Driver.attach(twin, armPose)
