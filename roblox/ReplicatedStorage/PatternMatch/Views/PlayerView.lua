-- ReplicatedStorage.PatternMatch.Views.PlayerView
-- Pattern Match for the player role and for spectators (Core.GameRegistry; also the lobby's player view).
-- It is everything the game shows on a player's screen, kept as inert templates in Views.Player and cloned
-- into PlayerGui on enter, destroyed on exit:
--   PatternHud (ScreenGui + HudClient)              ticket stack, status panel, results, Q / R, tremor shake
--   PatternModeSelect (ScreenGui + ModeSelectClient) the mode select shot and tiles, for the chooser
--   PatternWorld (Folder: CabinetFocus, ArmTwinClient) depth of field on the table, the stick arm twin
-- The boards, the Play prompt and the celebration are server-side parts in the room.
-- ctx.readOnly (spectators): every copy gets the attribute ReadOnly = true and its scripts send nothing to
-- the server (no Q / R, arrows or mode picks; the camera follows the player's instead, Core RoleClient).
-- On exit each copy first gets the attribute Exiting = true and one frame to clean up while its script is
-- still running (camera, tremor shake, the stick arm): a script's own Destroying handler can't be relied on
-- once the script itself is being destroyed. Then the copies go, and anything left over is removed here.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local templates = script.Parent:WaitForChild("Player")

local PlayerView = {}

local live = {}

function PlayerView.enter(ctx)
	PlayerView.exit()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, template in ipairs(templates:GetChildren()) do
		local copy = template:Clone()
		copy:SetAttribute("ReadOnly", ctx ~= nil and ctx.readOnly == true)
		copy.Parent = playerGui
		table.insert(live, copy)
	end
end

function PlayerView.exit()
	if #live == 0 then
		return
	end
	for _, copy in ipairs(live) do
		copy:SetAttribute("Exiting", true)
	end
	task.wait() -- the copies' scripts clean up on Exiting
	for _, copy in ipairs(live) do
		copy:Destroy()
	end
	table.clear(live)
	Players.LocalPlayer:SetAttribute("PatternShot", nil)
	pcall(RunService.UnbindFromRenderStep, RunService, "PatternTremor")
	local stick = workspace:FindFirstChild("PatternCabinet") and workspace.PatternCabinet:FindFirstChild("ArmStick")
	if stick then
		stick:Destroy()
	end
end

return PlayerView
