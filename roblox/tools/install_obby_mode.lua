-- Installs Robo Obby as an arcade mode into the arcade place (places/LeBot_Arcade.rbxl): every script,
-- module and remote (docs/obby-mode-plan.md). Run it in EDIT mode from the command bar, with the repo served
-- over local HTTP. It never touches the map: put ServerStorage.Modes.Obby.Map in first with
-- roblox/tools/prepare_obby_map.lua (see docs/obby-mode-plan.md "Getting the map in"). It checks the map
-- and says what is missing.
--
--   1. From the repo root:  python -m http.server 8771 --bind 127.0.0.1
--      (not 8765: that is the robot bridge's WebSocket port)
--   2. Studio command bar:
--        game:GetService("HttpService").HttpEnabled = true
--        loadstring(game:GetService("HttpService"):GetAsync("http://127.0.0.1:8771/roblox/tools/install_obby_mode.lua"))()
--   3. Read the report in Output, save the place, and stop the HTTP server.
--
-- Safe to run again: it updates sources in place, creates only what is missing, and removes Server modules
-- that are no longer in the manifest (an old copy of the obby's own Bridge, for one).
-- Leaves HttpEnabled as it found it (the arcade needs it on anyway: the robot link is a WebSocket).

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")
local ScriptEditorService = game:GetService("ScriptEditorService")

local BASE = "http://127.0.0.1:8771/roblox/"
local report = {}
local problems = {}

local function note(fmt, ...)
	table.insert(report, string.format(fmt, ...))
end
local function problem(fmt, ...)
	table.insert(problems, string.format(fmt, ...))
end

local function getOrCreate(parent, className, name)
	local child = parent:FindFirstChild(name)
	if child and child.ClassName ~= className then
		problem("%s was a %s, replaced with a %s", child:GetFullName(), child.ClassName, className)
		child:Destroy()
		child = nil
	end
	if not child then
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
		note("made %s (%s)", child:GetFullName(), className)
	end
	return child
end

local function fetch(path)
	local ok, body = pcall(function()
		return HttpService:GetAsync(BASE .. path, true)
	end)
	if not ok then
		error(string.format("could not fetch %s%s: %s (is `python -m http.server 8771` running in the repo root?)",
			BASE, path, tostring(body)))
	end
	return body
end

-- A script instance with its source from the repo file `path` (relative to roblox/).
local function install(parent, name, className, path)
	local inst = getOrCreate(parent, className, name)
	local source = fetch(path)
	local ok = pcall(function()
		ScriptEditorService:UpdateSourceAsync(inst, function()
			return source
		end)
	end)
	if not ok then
		inst.Source = source
	end
	note("%s <- roblox/%s (%d bytes)", inst:GetFullName(), path, #source)
	return inst
end

local wasEnabled = HttpService.HttpEnabled
HttpService.HttpEnabled = true

local ok, err = pcall(function()
	----------------------------------------------------------------- server: the mode + its Runtime modules
	local modes = getOrCreate(ServerStorage, "Folder", "Modes")
	local obbyMode = getOrCreate(modes, "Folder", "Obby")
	install(obbyMode, "Module", "ModuleScript", "ServerStorage/Modes/Obby/Module.lua")
	local server = getOrCreate(obbyMode, "Folder", "Server")
	local SERVER = {
		"RunControl", "BlockSync", "SkyArm", "ArmMirror", "HazardManager", "ActiveBayTracker", "BridgeFeed",
		"DebugMode", "Status", "DebugMenu", "GhostMode", "BayData", "CrateDefs", "Mapping",
	}
	for _, name in ipairs(SERVER) do
		install(server, name, "ModuleScript", "ServerStorage/Modes/Obby/Server/" .. name .. ".lua")
	end
	for _, child in ipairs(server:GetChildren()) do
		if not table.find(SERVER, child.Name) then
			note("removed %s (not in the manifest)", child:GetFullName())
			child:Destroy()
		end
	end
	local runtime = obbyMode:FindFirstChild("Runtime")
	if runtime then
		runtime:Destroy() -- a round's clone saved by accident; Start makes a fresh one
		note("removed a stale ServerStorage.Modes.Obby.Runtime")
	end

	----------------------------------------------------------------- shared: config, remotes, views
	local obby = getOrCreate(ReplicatedStorage, "Folder", "Obby")
	install(obby, "Config", "ModuleScript", "ReplicatedStorage/Obby/Config.lua")
	local remotes = getOrCreate(obby, "Folder", "Remotes")
	for _, name in ipairs({
		"Objective", "CellEdit", "CellsUpdated", "DebugHotkey", "GhostToggle", "DebugCommand", "Status", "BayCells",
		"CameraFace",
	}) do
		getOrCreate(remotes, "RemoteEvent", name)
	end
	local views = getOrCreate(obby, "Folder", "Views")
	install(views, "PlayerView", "ModuleScript", "ReplicatedStorage/Obby/Views/PlayerView.lua")
	install(views, "RobotView", "ModuleScript", "ReplicatedStorage/Obby/Views/RobotView.lua")
	-- LocalScript templates: inert in ReplicatedStorage, PlayerView clones them into PlayerGui
	local playerTemplates = getOrCreate(views, "Folder", "Player")
	for _, name in ipairs({ "ObjectiveHud", "CellEditor", "BackdropFx", "CameraPolish", "DarkRoom" }) do
		install(playerTemplates, name, "LocalScript", "ReplicatedStorage/Obby/Views/Player/" .. name .. ".client.lua")
	end
	local debugTemplates = getOrCreate(views, "Folder", "Debug")
	for _, name in ipairs({ "DebugMenu", "GhostControl" }) do
		install(debugTemplates, name, "LocalScript", "ReplicatedStorage/Obby/Views/Debug/" .. name .. ".client.lua")
	end

	----------------------------------------------------------------- the core registry entry
	local core = ReplicatedStorage:FindFirstChild("Core")
	local games = core and core:FindFirstChild("Games")
	if games then
		install(games, "Obby", "ModuleScript", "ReplicatedStorage/Core/Games/Obby.lua")
	else
		problem("ReplicatedStorage.Core.Games is missing: is this the arcade place? (no registry entry installed)")
	end

	----------------------------------------------------------------- checks: things this script doesn't make
	for _, path in ipairs({
		{ game:GetService("ServerScriptService"), { "HazardManager", "BridgeFeed", "DebugMode", "DebugMenu", "GhostMode",
			"ActiveBayTracker", "RunControl" } },
		{ game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"), { "OverseerCam", "ObjectiveHud",
			"DebugCellEditor", "GhostControl", "BackdropFx", "CameraPolish" } },
		{ ReplicatedStorage, { "Config", "BayData", "CrateDefs", "Remotes" } },
	}) do
		local parent, names = path[1], path[2]
		for _, name in ipairs(parent and names or {}) do
			if parent:FindFirstChild(name) then
				problem("%s.%s exists: if it is a standalone obby copy it runs outside the mode contract; remove it",
					parent:GetFullName(), name)
			end
		end
	end
	local sss = game:GetService("ServerScriptService")
	if not sss:FindFirstChild("Bridge") then
		problem("ServerScriptService.Bridge (the core's robot link) is missing; the obby will always run solo")
	end
	if not (ServerStorage:FindFirstChild("Shared") and ServerStorage.Shared:FindFirstChild("Bridge")) then
		problem("ServerStorage.Shared.Bridge is missing; Module.Start falls back to solo")
	end

	local map = obbyMode:FindFirstChild("Map")
	if not map then
		problem("ServerStorage.Modes.Obby.Map is missing: insert places/ObbyMap.rbxm (docs/obby-mode-plan.md)")
	else
		if not map:IsA("Model") then
			problem("Map is a %s, not a Model", map.ClassName)
		elseif map.ModelStreamingMode ~= Enum.ModelStreamingMode.Persistent then
			map.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
			note("set Map.ModelStreamingMode = Persistent")
		end
		for _, name in ipairs({ "Warehouse", "Backdrop", "Start", "Finish", "LobbyPad" }) do
			if not map:FindFirstChild(name) then
				problem("Map.%s is missing", name)
			end
		end
		local pad = map:FindFirstChild("LobbyPad")
		if pad and not CollectionService:HasTag(pad, "LobbyTeleporter") then
			CollectionService:AddTag(pad, "LobbyTeleporter")
			note("tagged Map.LobbyPad LobbyTeleporter")
		end
		for _, d in ipairs(map:GetDescendants()) do
			if d:IsA("SpawnLocation") then
				problem("%s is a SpawnLocation: arcade players could spawn into the obby (prepare_obby_map.lua converts it)",
					d:GetFullName())
			elseif d:IsA("BaseScript") then
				problem("%s is a script inside the map; maps hold no code", d:GetFullName())
			end
		end
		local bay1 = map:FindFirstChild("Warehouse") and map.Warehouse:FindFirstChild("Bay01")
		local anchor = bay1 and bay1:FindFirstChild("CrateAnchors") and bay1.CrateAnchors:FindFirstChild("Cell_0_0")
		local Config = require(obby.Config:Clone()) -- a clone: the command bar caches requires
		if anchor and math.abs(anchor.Position.Z - (Config.OriginZ + Config.CellSize / 2)) > 1 then
			problem("Bay01 Cell_0_0 is at Z %.1f; expected about %.1f (Config.OriginZ %d + half a cell). Map not moved?",
				anchor.Position.Z, Config.OriginZ + Config.CellSize / 2, Config.OriginZ)
		end
	end

	local workshop = workspace:FindFirstChild("Workshop")
	local bays = workshop and workshop:FindFirstChild("Bays")
	local cabinet = nil
	for _, bay in ipairs(bays and bays:GetChildren() or {}) do
		if (bay:GetAttribute("Mode") or bay.Name) == "Obby" then
			cabinet = bay
		end
	end
	if not cabinet then
		problem("no Workspace.Workshop.Bays.* with Mode = \"Obby\": the arcade has no portal for it")
	else
		note("cabinet: %s", cabinet:GetFullName())
	end
end)

HttpService.HttpEnabled = wasEnabled

print("[install_obby_mode] " .. (ok and "done" or "FAILED"))
for _, line in ipairs(report) do
	print("  " .. line)
end
if not ok then
	warn("[install_obby_mode] " .. tostring(err))
end
for _, line in ipairs(problems) do
	warn("[install_obby_mode] " .. line)
end
