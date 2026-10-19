-- ReplicatedStorage.PatternMatch.Views.PlayerView
-- Pattern Match for the player role and for spectators while Pattern Match is the active game
-- (Core.GameRegistry; the arcade mode sets it from Start to Stop).
-- It is everything the game shows on a player's screen, kept as inert templates in Views.Player and cloned
-- into PlayerGui on enter, destroyed on exit:
--   PatternHud (ScreenGui + HudClient)              ticket stack, status panel, results, Q / R
--   PatternModeSelect (ScreenGui + ModeSelectClient) the mode select shot and tiles, for the chooser
--   PatternWorld (Folder: CabinetFocus, ArmTwinClient) depth of field on the table, the stick arm twin
-- The boards and the celebration are server-side parts in the map (Workspace[Config.mapName]).
-- Nothing here touches Lighting (the arcade owns it): the depth of field is an effect under the camera.
-- ctx.readOnly (spectators): every copy gets the attribute ReadOnly = true and its scripts send nothing to
-- the server (no Q / R, arrows or mode picks; the camera follows the player's instead, Core RoleClient).
-- On exit each copy first gets the attribute Exiting = true and one frame to clean up while its script is
-- still running (camera, the stick arm): a script's own Destroying handler can't be relied on
-- once the script itself is being destroyed. Then the copies go, and anything left over is removed here:
-- the mode select shot flag, the depth of field under the camera, the stick arm.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Config"))
local templates = script.Parent:WaitForChild("Player")
local FOCUS_NAME = "PatternMatchFocus" -- PatternWorld.CabinetFocus's effect under the camera

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
	local camera = workspace.CurrentCamera
	local focus = camera and camera:FindFirstChild(FOCUS_NAME)
	if focus then
		focus:Destroy()
	end
	local map = workspace:FindFirstChild(Config.mapName)
	local stick = map and map:FindFirstChild("PatternCabinet") and map.PatternCabinet:FindFirstChild("ArmStick")
	if stick then
		stick:Destroy()
	end
end

return PlayerView
