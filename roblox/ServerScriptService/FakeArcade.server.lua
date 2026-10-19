-- ServerScriptService.FakeArcade
-- A Studio-only stand-in for the arcade (docs/arcade-plan.md "Portal flow"), off unless
-- ReplicatedStorage.PatternMatch.Config.fakeArcade is true. It runs ServerStorage.Modes.PatternMatch the
-- way ArcadeManager runs a mode, so Pattern Match can be tested without the arcade place:
--   - A small test lobby at the world origin (Workspace.FakeArcadeLobby): a floor, a SpawnLocation and a
--     green TEST PAD. Characters are scaled 1.5x, like the arcade's CharacterScale.
--   - Stepping on the pad (checked 4 times a second, like the arcade's portals) opens a short join window,
--     then Mode.Start(players) for everyone who stood on it, waits for Mode.Finished (at most
--     Mode.MaxDuration seconds), prints the results, calls Mode.Stop() and sends the players back to the
--     lobby spawn.
--   - Attributes on this script show what happened: Busy, Games (runs finished), LastResults
--     ("Name=WIN ..." or "TIMEOUT"), LastSeconds (Start to Finished), LastListForm (true when Finished
--     sent the list form, one { player, won } entry per player).
--   - ReplicatedStorage.PatternMatch.Debug:Fire({ op = "start", mode = "easy" / "hard" }) runs a game with
--     no players (solo robot-role testing) and picks that mode; add game = "<ServerStorage.Modes name>" (e.g.
--     "Flood") to run another mode. In the arcade place it also sets ReplicatedStorage.Arcade "ActiveMode" to
--     that mode's bay for the run, like ArcadeManager.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("PatternMatch"):WaitForChild("Config"))
if not (Config.fakeArcade and RunService:IsStudio()) then
	return
end

local CHARACTER_SCALE = 1.5 -- the arcade's CharacterScale
local JOIN_SECONDS = 3
local LOBBY_CENTER = Vector3.new(0, 0, 0)

local Mode = require(ServerStorage:WaitForChild("Modes"):WaitForChild("PatternMatch"):WaitForChild("Module"))

local function log(fmt, ...)
	print("[FakeArcade] " .. string.format(fmt, ...))
end

-- The test lobby -------------------------------------------------------------------------------------

local lobby = Instance.new("Folder")
lobby.Name = "FakeArcadeLobby"

local function part(name, size, cframe, color, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	for k, v in pairs(props or {}) do
		p[k] = v
	end
	p.Parent = lobby
	return p
end

part("Floor", Vector3.new(70, 1, 70), CFrame.new(LOBBY_CENTER + Vector3.new(0, -0.5, 0)), Color3.fromRGB(52, 54, 66),
	{ Material = Enum.Material.SmoothPlastic })
local spawnLocation = Instance.new("SpawnLocation")
spawnLocation.Name = "Spawn"
spawnLocation.Anchored = true
spawnLocation.Size = Vector3.new(8, 0.4, 8)
spawnLocation.CFrame = CFrame.new(LOBBY_CENTER + Vector3.new(0, 0.2, 18))
spawnLocation.Color = Color3.fromRGB(90, 90, 110)
spawnLocation.Duration = 0
spawnLocation.Parent = lobby
local pad = part("TestPad", Vector3.new(10, 0.4, 10), CFrame.new(LOBBY_CENTER + Vector3.new(0, 0.2, -10)),
	Color3.fromRGB(60, 200, 110), { Material = Enum.Material.Neon })

local sign = Instance.new("BillboardGui")
sign.Name = "Sign"
sign.Size = UDim2.fromOffset(360, 90)
sign.StudsOffset = Vector3.new(0, 7, 0)
sign.AlwaysOnTop = true
sign.Parent = pad
local signText = Instance.new("TextLabel")
signText.Size = UDim2.fromScale(1, 1)
signText.BackgroundTransparency = 1
signText.Font = Enum.Font.GothamBlack
signText.TextScaled = true
signText.TextColor3 = Color3.new(1, 1, 1)
signText.TextStrokeTransparency = 0.3
signText.Parent = sign
local function setSign(text)
	signText.Text = text
end
setSign("FAKE ARCADE\nstep on the pad: " .. Mode.DisplayName)

lobby.Parent = workspace

-- 1.5x characters, like the arcade --------------------------------------------------------------------

local function scaleCharacter(player, character)
	if not player:HasAppearanceLoaded() then
		local loaded = false
		local connection = player.CharacterAppearanceLoaded:Connect(function()
			loaded = true
		end)
		local t0 = os.clock()
		while not loaded and os.clock() - t0 < 5 do
			task.wait()
		end
		connection:Disconnect()
	end
	if character.Parent and player.Character == character then
		character:ScaleTo(CHARACTER_SCALE)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = game.StarterPlayer.CharacterWalkSpeed
			humanoid.JumpHeight = game.StarterPlayer.CharacterJumpHeight
		end
	end
end

local function watchCharacters(player)
	player.CharacterAdded:Connect(function(character)
		scaleCharacter(player, character)
	end)
	if player.Character then
		task.spawn(scaleCharacter, player, player.Character)
	end
end
Players.PlayerAdded:Connect(watchCharacters)
for _, player in ipairs(Players:GetPlayers()) do
	watchCharacters(player)
end

-- The run, like ArcadeManager.runGame -----------------------------------------------------------------

local busy = false
local joining = false -- the join window is open
local joined = {}
script:SetAttribute("Busy", false)
script:SetAttribute("Games", 0)

local function waitForFinished(Mode, timeout)
	local result
	local fired = 0
	local connection = Mode.Finished.Event:Connect(function(r)
		fired += 1
		if result == nil then
			result = r or {}
		end
	end)
	local t0 = os.clock()
	while result == nil and os.clock() - t0 < timeout do
		task.wait(0.1)
	end
	task.wait(0.5) -- catch a second Fire, if there ever is one
	connection:Disconnect()
	return result, os.clock() - t0, fired
end

local function runGame(pickMode, gameName)
	local Mode = Mode
	if gameName then
		Mode = require(ServerStorage.Modes:WaitForChild(gameName):WaitForChild("Module"))
	end
	local arcade = ReplicatedStorage:FindFirstChild("Arcade")
	local bays = workspace:FindFirstChild("Workshop") and workspace.Workshop:FindFirstChild("Bays")
	local bay = nil
	for _, b in ipairs(bays and bays:GetChildren() or {}) do
		if b:GetAttribute("Mode") == (gameName or "PatternMatch") then
			bay = b
		end
	end
	joining = false
	local players = {}
	for _, p in ipairs(joined) do
		if p.Parent and p.Character then
			table.insert(players, p)
		end
	end
	table.clear(joined)
	setSign("PLAYING " .. string.upper(Mode.DisplayName))
	log("Start %s with %d player%s (MaxDuration %d s)", Mode.DisplayName or "?", #players, #players == 1 and "" or "s", Mode.MaxDuration or 180)

	local results, seconds, fired = nil, 0, 0
	if arcade and bay then
		arcade:SetAttribute("ActiveMode", bay.Name)
	end
	local ok, err = pcall(Mode.Start, players)
	if ok then
		if pickMode and not gameName then
			ReplicatedStorage.PatternMatch.Debug:Fire({ op = "pick", mode = pickMode })
		end
		results, seconds, fired = waitForFinished(Mode, Mode.MaxDuration or 180)
	else
		warn("[FakeArcade] Start failed: " .. tostring(err))
	end

	local listForm = type(results) == "table" and #results == #players
	local summary = {}
	if results == nil then
		table.insert(summary, "TIMEOUT")
		warn("[FakeArcade] the game timed out without firing Finished")
	else
		for _, r in ipairs(results) do
			listForm = listForm and type(r) == "table" and typeof(r.player) == "Instance" and type(r.won) == "boolean"
			table.insert(summary, string.format("%s=%s", r.player and r.player.Name or "?", r.won and "WIN" or "LOSE"))
		end
		log("Finished after %.1f s (fired %d time%s): %s", seconds, fired, fired == 1 and "" or "s",
			#summary > 0 and table.concat(summary, " ") or "(no players)")
	end

	local stopped, stopErr = pcall(Mode.Stop)
	if arcade and bay then
		arcade:SetAttribute("ActiveMode", "")
	end
	if not stopped then
		warn("[FakeArcade] Stop failed: " .. tostring(stopErr))
	end
	for i, p in ipairs(players) do -- back to the lobby, like the arcade's return points
		if p.Parent and p.Character then
			p.Character:PivotTo(spawnLocation.CFrame + Vector3.new((i - 1) * 5, 5, 0))
		end
	end
	script:SetAttribute("LastResults", table.concat(summary, " "))
	script:SetAttribute("LastSeconds", math.floor(seconds * 10 + 0.5) / 10)
	script:SetAttribute("LastListForm", listForm and fired == 1)
	script:SetAttribute("Games", script:GetAttribute("Games") + 1)
	setSign("FAKE ARCADE\nstep on the pad: " .. Mode.DisplayName)
	script:SetAttribute("Busy", false)
	busy = false
end

local function openJoinWindow(first, pickMode, gameName)
	busy = true -- before anything yields
	script:SetAttribute("Busy", true)
	joined = first and { first } or {}
	joining = true
	task.spawn(function()
		if first then
			for t = JOIN_SECONDS, 1, -1 do
				setSign(string.format("STARTING IN %d", t))
				task.wait(1)
			end
		end
		runGame(pickMode, gameName)
	end)
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
task.spawn(function()
	while true do
		local characters = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then
				table.insert(characters, p.Character)
			end
		end
		overlap.FilterDescendantsInstances = characters
		local seen = {}
		for _, hit in ipairs(workspace:GetPartBoundsInBox(pad.CFrame + Vector3.new(0, 3, 0), pad.Size + Vector3.new(0, 6, 0), overlap)) do
			local player = Players:GetPlayerFromCharacter(hit.Parent)
			if player and not seen[player] then
				seen[player] = true
				if not busy then
					openJoinWindow(player)
				elseif joining and not table.find(joined, player) then
					table.insert(joined, player)
				end
			end
		end
		task.wait(0.25)
	end
end)

ReplicatedStorage.PatternMatch:WaitForChild("Debug").Event:Connect(function(cmd)
	if type(cmd) == "table" and cmd.op == "start" and not busy then
		openJoinWindow(nil, cmd.mode == "hard" and "hard" or "easy", type(cmd.game) == "string" and cmd.game or nil)
	end
end)

log("on: step on the TEST PAD to play %s", Mode.DisplayName)
