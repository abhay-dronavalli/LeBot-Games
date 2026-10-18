-- Edit-time build script for ReplicatedStorage.ArmTwin: the SO-101 twin Model, built from parts by
-- ArmTwin.Rig. Not part of the game: run it once in Studio's command bar (or via the MCP execute_luau
-- tool) after the ArmTwin Model with its Rig and Driver ModuleScripts exists, and before
-- build_pattern_cabinet.lua, which clones the twin next to the LiveBoard. Undo with Ctrl+Z.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local model = ReplicatedStorage:FindFirstChild("ArmTwin")
assert(model and model:IsA("Model"), "ReplicatedStorage.ArmTwin Model (with Rig and Driver) is missing")
assert(not model:FindFirstChildOfClass("BasePart"), "ReplicatedStorage.ArmTwin already has parts")

-- Studio's command-bar require cache keeps the first version of a module it loaded this session, so an
-- edited Config would come back stale. Swapping the ModuleScript for an identical copy forces a fresh
-- load; requiring a clone of Rig does the same for Rig itself.
local function freshen(module)
	local copy = module:Clone()
	local parent = module.Parent
	module:Destroy()
	copy.Parent = parent
	return copy
end
freshen(ReplicatedStorage.PatternMatch.Config)
assert(require(ReplicatedStorage.PatternMatch.Config).twinLinksCm, "Config has no twinLinksCm")
local Rig = require(model.Rig:Clone())

local recording = ChangeHistoryService:TryBeginRecording("Build ArmTwin")
Rig.build(model)
if recording then
	ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
end

local parts, motors = 0, 0
for _, d in ipairs(model:GetDescendants()) do
	if d:IsA("BasePart") then parts += 1 elseif d:IsA("Motor6D") then motors += 1 end
end
return string.format("built %s: %d parts, %d Motor6Ds, tip at rest %s studs", model:GetFullName(), parts, motors,
	tostring(Rig.forward({}).Position))
