-- Packages Pattern Match as an arcade mode (docs/arcade-plan.md "Mode contract"). Run once in Edit mode
-- (command bar or MCP execute_luau), after the build tools (build_room, build_pattern_cabinet, ...) have
-- built the bedroom and the cabinet in Workspace:
--   Workspace.Room + Workspace.PatternCabinet -> ServerStorage.Modes.PatternMatch.Map (a Model,
--   ModelStreamingMode Persistent), moved to PatternMatch.Config.mapOffset, far from the arcade origin.
--   The Play pad (PatternCabinet.Entry and its "Play Pattern Match" prompt) stays: the arcade's Start puts
--   players in the room and pressing Play opens mode select.
--   The SpawnLocation becomes a plain mat (a SpawnLocation in the map would respawn arcade players into
--   the room), and a StartSpot marks where Mode.Start puts the players: 5 studs behind the Play pad (toward
--   the mat), facing the table, within the prompt's reach.
--   Lighting.CabinetFocus is removed: the arcade owns Lighting; the depth of field now lives under each
--   client's camera while the Pattern Match view is up.
-- Safe to run again: it only moves what is still in Workspace.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")

local Config = require(ReplicatedStorage.PatternMatch.Config:Clone()) -- a clone: the command bar caches requires
local report = {}

local function getOrCreate(parent, className, name)
	local child = parent:FindFirstChild(name)
	if not child then
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end

local modes = getOrCreate(ServerStorage, "Folder", "Modes")
local folder = getOrCreate(modes, "Folder", "PatternMatch")
local map = folder:FindFirstChild("Map")
if not map then
	map = Instance.new("Model")
	map.Name = "Map"
	map.WorldPivot = CFrame.new()
	map.Parent = folder
	table.insert(report, "made ServerStorage.Modes.PatternMatch.Map")
end
map.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

local moved = false
for _, name in ipairs({ "Room", "PatternCabinet" }) do
	local inst = workspace:FindFirstChild(name)
	if inst then
		inst.Parent = map
		moved = true
		table.insert(report, "moved Workspace." .. name .. " into the Map")
	end
end
if moved then
	-- Everything was built around the world origin; the Map's pivot is that origin.
	map.WorldPivot = CFrame.new()
	map:PivotTo(CFrame.new(Config.mapOffset))
	table.insert(report, "Map moved to " .. tostring(Config.mapOffset))
end

local cabinet = map:FindFirstChild("PatternCabinet")
local entry = cabinet and cabinet:FindFirstChild("Entry")
local startCFrame = nil
if entry then
	-- Stand on the floor 5 studs behind the pad, facing the table (-Z).
	startCFrame = CFrame.new(entry.Position.X, entry.Position.Y - entry.Size.Y / 2, entry.Position.Z + 5)
	local prompt = entry:FindFirstChild("PlayPrompt")
	if prompt then
		prompt.MaxActivationDistance = 10 -- reaches 1.5x characters on the start spot
	end
end

local room = map:FindFirstChild("Room")
local spawnFolder = room and room:FindFirstChild("Spawn")
local spawnLocation = spawnFolder and spawnFolder:FindFirstChildWhichIsA("SpawnLocation")
if spawnLocation then
	local mat = Instance.new("Part")
	mat.Name = "Mat"
	for _, prop in ipairs({ "Size", "CFrame", "Color", "Material", "Transparency", "Reflectance", "TopSurface",
		"BottomSurface", "CastShadow" }) do
		mat[prop] = spawnLocation[prop]
	end
	mat.Anchored, mat.CanCollide = true, true
	for _, child in ipairs(spawnLocation:GetChildren()) do
		if not child:IsA("Decal") or child.Name ~= "Decal" then -- the default spawn decal stays behind
			child.Parent = mat
		end
	end
	mat.Parent = spawnFolder
	spawnLocation:Destroy()
	table.insert(report, "SpawnLocation -> plain Part Room.Spawn.Mat")
end

if cabinet and startCFrame and not cabinet:FindFirstChild("StartSpot") then
	local spot = Instance.new("Part")
	spot.Name = "StartSpot"
	spot.Anchored, spot.CanCollide, spot.CanQuery, spot.CanTouch = true, false, false, false
	spot.Transparency = 1
	spot.Size = Vector3.new(4, 0.2, 4)
	spot.CFrame = startCFrame + Vector3.new(0, 0.1, 0) -- its top is the floor; facing -Z, toward the table
	spot.Parent = cabinet
	table.insert(report, "added PatternCabinet.StartSpot at " .. tostring(spot.Position))
end

local focus = Lighting:FindFirstChild("CabinetFocus")
if focus then
	focus:Destroy()
	table.insert(report, "removed Lighting.CabinetFocus")
end

return #report > 0 and table.concat(report, "\n") or "nothing to do: already packaged"
