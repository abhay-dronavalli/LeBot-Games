-- Studio location: ServerStorage.Modes.Flood.Themes.Sewer.ThemeServer (ModuleScript)
--[[
	Sewer theme, server side (hooks called by the Flood module).

	- Sticky sludge: while a player's feet are in the sludge (but they aren't flooded yet),
	  WalkSpeed and JumpHeight drop to the values in Settings; they come back as soon as the
	  player climbs out. Reaching the waist still means "flooded", exactly like Water.
	- Climbing blocks are restyled as wooden crates (and the odd painted cube).
	Lighting, sounds and all other visuals are client-side (ReplicatedStorage.Flood.Themes.Sewer).
]]

local StarterPlayer = game:GetService("StarterPlayer")

local Hooks = {}

local WOOD = Color3.fromRGB(139, 94, 60)
local IRON = Color3.fromRGB(45, 45, 42)
local YELLOW = Color3.fromRGB(245, 197, 24)
local BLACK = Color3.fromRGB(28, 31, 36)
local PAINTED = { Color3.fromRGB(235, 190, 40), Color3.fromRGB(110, 112, 116) }

local function rootOf(player)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hrp and hum.Health > 0 then
		return hrp, hum
	end
end

local function restore(player)
	local _, hum = rootOf(player)
	if hum then
		hum.WalkSpeed = StarterPlayer.CharacterWalkSpeed
		hum.JumpHeight = StarterPlayer.CharacterJumpHeight
	end
end

function Hooks.apply(s)
	s.sticky = {}
end

function Hooks.onHeartbeat(s)
	local settings = s.settings
	local walk = settings and settings:GetAttribute("StickyWalkSpeed") or 8
	local jumpMult = settings and settings:GetAttribute("StickyJumpMultiplier") or 0.7
	local surfaceY = s.floorY + math.max(s.waterLevel, 0)
	for p in s.players do
		if s.flooded[p] or not p.Parent then
			s.sticky[p] = nil -- Flood's waterlogged values take over
		else
			local hrp, hum = rootOf(p)
			if hrp then
				local feet = hrp.Position.Y - hum.HipHeight - hrp.Size.Y / 2
				local inSludge = feet < surfaceY - 0.1
				if inSludge and not s.sticky[p] then
					s.sticky[p] = true
					hum.WalkSpeed = walk
					hum.JumpHeight = StarterPlayer.CharacterJumpHeight * jumpMult
				elseif not inSludge and s.sticky[p] then
					s.sticky[p] = nil
					restore(p)
				end
			end
		end
	end
end

local function deco(model, name, size, cf, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- Turn the plain cube + ledge into a crate. Called before the block drops in.
function Hooks.styleBlock(model, k)
	local cube = model:FindFirstChild("Cube")
	local ledge = model:FindFirstChild("Ledge")
	if not cube then
		return
	end
	if ledge then
		ledge.Material = Enum.Material.WoodPlanks
		ledge.Color = WOOD:Lerp(Color3.new(0, 0, 0), 0.2)
	end
	if k % 3 == 0 then
		-- every third block is a plain painted cube, like the concept art
		cube.Material = Enum.Material.SmoothPlastic
		cube.Color = PAINTED[(k // 3 - 1) % #PAINTED + 1]
		return
	end
	cube.Material = Enum.Material.WoodPlanks
	cube.Color = WOOD
	local sz = cube.Size
	local cf = cube.CFrame
	-- dark iron corner brackets
	for _, sx in { -1, 1 } do
		for _, sz2 in { -1, 1 } do
			deco(model, "CornerBracket", Vector3.new(0.6, sz.Y + 0.05, 0.6), cf * CFrame.new(sx * (sz.X / 2 - 0.2), 0, sz2 * (sz.Z / 2 - 0.2)), IRON, Enum.Material.Metal)
		end
	end
	-- diagonal cross plank on each side face
	local diag = math.sqrt(sz.X ^ 2 + sz.Y ^ 2) - 0.8
	local ang = math.atan2(sz.Y, sz.X)
	for _, f in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local off = if f[1] ~= 0 then Vector3.new(f[1] * (sz.X / 2 + 0.08), 0, 0) else Vector3.new(0, 0, f[2] * (sz.Z / 2 + 0.08))
		local rot = if f[1] ~= 0 then CFrame.Angles(0, math.rad(90), 0) else CFrame.identity
		deco(model, "CrossPlank", Vector3.new(diag, 0.7, 0.15), cf * CFrame.new(off) * rot * CFrame.Angles(0, 0, ang * (k % 2 == 0 and 1 or -1)), WOOD:Lerp(Color3.new(1, 1, 1), 0.08), Enum.Material.WoodPlanks)
	end
	-- hazard band on some crates
	if k % 2 == 0 then
		for i = 0, 3 do
			deco(model, "HazardBand", Vector3.new(sz.X + 0.1, 0.5, sz.Z + 0.1), cf * CFrame.new(0, -0.75 + i * 0.5, 0), if i % 2 == 0 then YELLOW else BLACK)
		end
	end
end

function Hooks.revert(s)
	for p in s.sticky or {} do
		if p.Parent then
			restore(p)
		end
	end
	s.sticky = {}
end

return Hooks
