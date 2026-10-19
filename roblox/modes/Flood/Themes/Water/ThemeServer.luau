-- Studio location: ServerStorage.Modes.Flood.Themes.Water.ThemeServer (ModuleScript)
--[[
	Water theme, server side (hooks called by the Flood module).
	The chamber has 8 painted depth lines (DepthLine1-8) and labels (DepthTag1-8). The tower's step
	height and length change with the difficulty, so each round they're moved to the real ledge
	heights, the top ledge is labelled SAFE LINE, and any extra lines are hidden.
]]

local Hooks = {}

local CYAN = Color3.fromRGB(70, 210, 255)
local GOLD = Color3.fromRGB(250, 200, 40)

function Hooks.apply(s)
	local decor = s.arena:FindFirstChild("Decor")
	if not decor then
		return
	end
	local lines = {}
	for k = 1, 8 do
		lines[k] = {}
	end
	for _, p in decor:GetChildren() do
		local k = tonumber(p.Name:match("^DepthLine(%d+)$"))
		if k and lines[k] then
			table.insert(lines[k], p)
		end
	end
	for k = 1, 8 do
		-- up to 8 lines: one per ledge, or spread evenly over a longer tower
		local level = if s.target <= 8 then k else math.round(k * s.target / 8)
		local shown = level <= s.target
		local safe = level == s.target
		local y = s.floorY + level * s.step
		for _, line in lines[k] do
			line.Transparency = if not shown then 1 elseif safe then 0 else 0.6
			line.Color = if safe then GOLD else CYAN
			line.Size = Vector3.new(line.Size.X, if safe then 0.5 else 0.25, line.Size.Z)
			line.CFrame = CFrame.new(line.Position.X, y, line.Position.Z)
		end
		local tag = decor:FindFirstChild("DepthTag" .. k)
		if tag then
			tag.CFrame = CFrame.new(tag.Position.X, y + 1.4, tag.Position.Z) * (tag.CFrame - tag.CFrame.Position)
			local label = tag:FindFirstChildWhichIsA("TextLabel", true)
			if label then
				label.Text = if not shown then "" elseif safe then "SAFE LINE " .. level else "LEVEL " .. level
				label.TextColor3 = if safe then GOLD else CYAN
			end
		end
	end
end

return Hooks
