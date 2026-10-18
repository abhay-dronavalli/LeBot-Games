-- StarterPlayer.StarterPlayerScripts.ArmTwinClient
-- Makes the arm twin next to the LiveBoard follow the real arm on this client: the server broadcasts the
-- arm as world points over the LiveBoard on PatternMatch.Remotes.ArmPose (from the bridge's arm.points)
-- and ArmTwin.Stick draws it as a stick figure, easing toward each sample. With no arm data (before the
-- first sample, an empty sample, or none for Stick.STALE_SECONDS) it settles into the folded rest pose.
-- The parts-built Motor6D rig (LiveBoard.ArmTwin) is hidden on this client and only gives the rest pose
-- its place; its joint-angle driver (ArmTwin.Driver.attach) is kept but not used.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Stick = require(ReplicatedStorage:WaitForChild("ArmTwin"):WaitForChild("Stick"))
local armPose = ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Remotes"):WaitForChild("ArmPose")
local cabinet = workspace:WaitForChild("PatternCabinet")
local twin = cabinet:WaitForChild("LiveBoard"):WaitForChild("ArmTwin")
twin:WaitForChild("Base")

Stick.attach(twin, armPose, cabinet)
