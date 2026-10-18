-- ReplicatedStorage.Obby.Views.PlayerView (ModuleScript)
-- Robo Obby for the player role and for spectators while the Obby is the active game (Core.GameRegistry;
-- the arcade sets it while the Obby bay's round runs). The PatternMatch PlayerView pattern: everything the
-- game shows on a runner's screen is kept as inert LocalScript templates and cloned into PlayerGui on
-- enter, destroyed on exit:
--   Views.Player.ObjectiveHud   the task panel, the bay countdown and the run clock pill
--   Views.Player.CellEditor     the on-screen 4x3 grid that places blocks: solo only
--                               (ReplicatedStorage.Obby FeedMode == "solo"; follows FeedMode while entered)
--   Views.Player.BackdropFx     the hall's gears, lamps and steam (client-side, tagged parts in the map)
--   Views.Player.CameraPolish   the camera faces teleports and respawns; low ceilings cap the zoom
--   Views.Player.DarkRoom       the dark room's darkness: a ColorCorrectionEffect "ObbyDark" under the camera
--   Views.Debug.DebugMenu, Views.Debug.GhostControl   only when ReplicatedStorage.Obby ArcadeDebug == true
-- ctx.readOnly (spectators): only ObjectiveHud and BackdropFx, with the attribute ReadOnly = true (they
-- send nothing; the camera follows the player's, Core RoleClient).
-- Nothing here touches Lighting (the arcade owns it): the dark room is the effect under the camera.
-- On exit each copy first gets the attribute Exiting = true and one frame to clean up while its script is
-- still running (camera, zoom cap, its ScreenGui): a script's own Destroying handler can't be relied on
-- once the script itself is being destroyed. Then the copies go, and anything left over is removed here:
-- every PlayerGui child with the attribute ObbyView = true (each copy's ScreenGui has it) and ObbyDark.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Obby = ReplicatedStorage:WaitForChild("Obby")
local playerTemplates = script.Parent:WaitForChild("Player")
local debugTemplates = script.Parent:WaitForChild("Debug")

local DARK_NAME = "ObbyDark" -- Views.Player.DarkRoom's effect under the camera
local READ_ONLY = {ObjectiveHud = true, BackdropFx = true}
local SOLO_ONLY = {CellEditor = true}

local PlayerView = {}

local live = {} -- template -> its copy in PlayerGui
local connections = {}
local entered = nil -- the ctx while entered

-- Should this template have a copy right now?
local function wanted(template, fromDebug)
	if not template:IsA("LocalScript") then
		return false
	end
	local readOnly = entered.readOnly == true
	if fromDebug then
		return not readOnly and Obby:GetAttribute("ArcadeDebug") == true
	end
	if readOnly then
		return READ_ONLY[template.Name] == true
	end
	if SOLO_ONLY[template.Name] then
		return Obby:GetAttribute("FeedMode") == "solo"
	end
	return true
end

local function remove(template)
	local copy = live[template]
	if not copy then
		return
	end
	live[template] = nil
	copy:SetAttribute("Exiting", true)
	-- The copy destroys its own ScreenGui on Exiting; whatever it leaves goes in exit's ObbyView sweep.
	task.spawn(function()
		task.wait() -- the copy's script cleans up on Exiting
		copy:Destroy()
	end)
end

-- Adds and removes copies to match what is wanted (enter, and FeedMode / ArcadeDebug changes).
local function sync()
	if not entered then
		return
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	for _, entry in ipairs({{playerTemplates, false}, {debugTemplates, true}}) do
		for _, template in ipairs(entry[1]:GetChildren()) do
			local want = wanted(template, entry[2])
			if want and not live[template] then
				local copy = template:Clone()
				copy:SetAttribute("ReadOnly", entered.readOnly == true)
				copy.Parent = playerGui
				live[template] = copy
			elseif not want and live[template] then
				remove(template)
			end
		end
	end
end

function PlayerView.enter(ctx)
	PlayerView.exit()
	entered = ctx or {}
	table.insert(connections, Obby:GetAttributeChangedSignal("FeedMode"):Connect(sync))
	table.insert(connections, Obby:GetAttributeChangedSignal("ArcadeDebug"):Connect(sync))
	sync()
end

function PlayerView.exit()
	for _, c in ipairs(connections) do
		c:Disconnect()
	end
	table.clear(connections)
	entered = nil
	local copies = {}
	for _, copy in pairs(live) do
		copy:SetAttribute("Exiting", true)
		table.insert(copies, copy)
	end
	table.clear(live)
	if #copies > 0 then
		task.wait() -- the copies' scripts clean up on Exiting
		for _, copy in ipairs(copies) do
			copy:Destroy()
		end
	end
	local playerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	for _, child in ipairs(playerGui and playerGui:GetChildren() or {}) do
		if child:GetAttribute("ObbyView") == true then
			child:Destroy()
		end
	end
	local camera = workspace.CurrentCamera
	local dark = camera and camera:FindFirstChild(DARK_NAME)
	if dark then
		dark:Destroy()
	end
end

return PlayerView
