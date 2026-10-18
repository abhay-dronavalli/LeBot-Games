-- build/scope_course.lua -- make the built course match Config.NumBays.
--
-- The warehouse geometry is baked for 9 bays. Scoping down to 4 obstacles means the other
-- five bays have to stop existing as far as the player is concerned -- otherwise you walk out
-- of the last real bay into 150 studs of empty rooms with no floor hazards and no way to tell
-- the game has ended.
--
-- REVERSIBLE BY DESIGN. Nothing is deleted. Out-of-scope bays, catwalks and racks are moved
-- into ServerStorage.OutOfScope, and moved back when NumBays goes up again. Raise NumBays,
-- re-run, and the course grows back.
--
-- Run from the Studio command bar in EDIT mode (geometry changed during a playtest is
-- discarded when you stop):
--
--     loadstring(game:GetService("HttpService")
--         :GetAsync("http://127.0.0.1:8767/scope_course.lua"))()
--
-- Config is read from SOURCE, not required: Studio's Edit datamodel caches required modules
-- for the session and editing a ModuleScript does not invalidate that cache, so require()
-- here returns a Config from whenever anything first asked. See build/fit_shell.lua.

local ServerStorage = game:GetService("ServerStorage")

local function configNumber(name, fallback)
	local src = game.ReplicatedStorage:WaitForChild("Config").Source
	local v = src:match("[\r\n]Config%." .. name .. "%s*=%s*(%-?[%d%.]+)")
	return tonumber(v) or fallback
end

local warehouse = workspace:WaitForChild("Warehouse")
local argv = {...}
local keep = tonumber(argv[1]) or configNumber("NumBays", 9)
local pitch = configNumber("BayPitch", 30)
local depth = configNumber("BayDepth", 24)
local entrance = configNumber("EntranceBuffer", 10)
local finale = configNumber("FinaleBuffer", 10)
local wallHeight = configNumber("WallHeight", 48)
local gantryHeight = configNumber("GantryHeight", 18)

-- Where the playable course now ends, and where the shell should stop.
local courseEnd = (keep - 1) * pitch + depth
local shellStart = -entrance
local shellEnd = courseEnd + finale
local shellLen = shellEnd - shellStart
local shellMid = (shellStart + shellEnd) / 2

local report = {}
local function note(...)
	table.insert(report, string.format(...))
end
note("  keeping bays 1-%d; course ends at z=%d, shell spans %d..%d",
	keep, courseEnd, shellStart, shellEnd)

local parked = ServerStorage:FindFirstChild("OutOfScope")
if not parked then
	parked = Instance.new("Folder")
	parked.Name = "OutOfScope"
	parked.Parent = ServerStorage
end

-- Bring anything back that is in scope again, before deciding what to park.
local restored = 0
for _, m in ipairs(parked:GetChildren()) do
	local home = m:GetAttribute("ScopeHome")
	local idx = tonumber(m.Name:match("Bay(%d+)"))
	local keepIt = (idx == nil) or (idx <= keep)
	if keepIt and home then
		local dest = warehouse:FindFirstChild(home)
		if dest then
			m.Parent = dest
			restored += 1
		end
	end
end
if restored > 0 then
	note("  restored %d object(s) from a previous, smaller scope", restored)
end

-- Park whole bays past the cut.
local parkedBays = 0
for i = keep + 1, 9 do
	local bay = warehouse:FindFirstChild(("Bay%02d"):format(i))
	if bay then
		bay:SetAttribute("ScopeHome", "Warehouse")
		bay.Parent = parked
		parkedBays += 1
	end
end
note("  parked %d bay model(s)", parkedBays)

-- Park the scenery that sits past the end: catwalks and pallet racks are positioned by Z, so
-- filter on that rather than on a name, which keeps this working if the layout is regenerated.
local function pivotZ(m)
	if m:IsA("BasePart") then
		return m.Position.Z
	end
	local ok, cf = pcall(function()
		return m:GetPivot()
	end)
	return ok and cf.Position.Z or 0
end

local parkedScenery = 0
for _, folderName in ipairs({"Catwalks", "PalletRacks"}) do
	local folder = warehouse:FindFirstChild(folderName)
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if pivotZ(m) > courseEnd then
				m:SetAttribute("ScopeHome", folderName)
				m.Parent = parked
				parkedScenery += 1
			end
		end
	end
end
note("  parked %d catwalk/rack object(s) past z=%d", parkedScenery, courseEnd)

-- The shell and the rails shrink to the new length so the room ends where the course does.
local shell = warehouse:FindFirstChild("Shell")
if shell then
	for _, p in ipairs(shell:GetChildren()) do
		if p:IsA("BasePart") then
			if p.Name == "EndCapFront" then
				p.Position = Vector3.new(p.Position.X, wallHeight / 2, shellEnd)
				p.Size = Vector3.new(p.Size.X, wallHeight, p.Size.Z)
			elseif p.Name == "EndCapBack" then
				p.Position = Vector3.new(p.Position.X, wallHeight / 2, shellStart)
				p.Size = Vector3.new(p.Size.X, wallHeight, p.Size.Z)
			else
				p.Size = Vector3.new(p.Size.X, wallHeight, shellLen)
				p.Position = Vector3.new(p.Position.X, wallHeight / 2, shellMid)
			end
		end
	end
	note("  shell walls now %d long, centred on z=%d", shellLen, shellMid)
end

local rails = warehouse:FindFirstChild("SkyRails")
if rails then
	local parkedTrusses = 0
	for _, p in ipairs(rails:GetChildren()) do
		if p:IsA("BasePart") then
			if p.Name:match("^Truss_") then
				if p.Position.Z > shellEnd then
					p:SetAttribute("ScopeHome", "SkyRails")
					p.Parent = parked
					parkedTrusses += 1
				else
					p.Position = Vector3.new(p.Position.X, wallHeight - 2, p.Position.Z)
				end
			else
				-- the beams the trolley rides: shortened, never raised
				p.Size = Vector3.new(p.Size.X, p.Size.Y, shellLen)
				p.Position = Vector3.new(p.Position.X, gantryHeight, shellMid)
			end
		end
	end
	note("  rails shortened to %d; parked %d truss(es) past the end", shellLen, parkedTrusses)
end

print("[scope_course] course scoped to " .. keep .. " bays:\n" .. table.concat(report, "\n"))
return table.concat(report, "\n")
