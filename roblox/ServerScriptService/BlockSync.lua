-- BlockSync -- nothing else in the game hard-codes a world position. cellToWorld reads the
-- Cell_c_r anchor parts baked into each bay prefab, so moving a bay moves everything with it.
-- Also owns the crate props themselves: how they look and where they sit.
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local BlockSync = {}

local COLOR_RGB = {
	red = Color3.fromRGB(210, 50, 50),
	blue = Color3.fromRGB(60, 150, 220),
	yellow = Color3.fromRGB(225, 200, 50),
	green = Color3.fromRGB(70, 190, 90),
	orange = Color3.fromRGB(230, 130, 30),
	purple = Color3.fromRGB(150, 80, 200),
	teal = Color3.fromRGB(50, 190, 180),
}

function BlockSync.cellToWorld(bayModel, col, row)
	local anchorsFolder = bayModel:FindFirstChild("CrateAnchors")
	if not anchorsFolder then
		error(string.format("BlockSync.cellToWorld: %s has no CrateAnchors folder", bayModel:GetFullName()))
	end

	local anchorName = string.format("Cell_%d_%d", col, row)
	local anchor = anchorsFolder:FindFirstChild(anchorName)
	if not anchor then
		error(string.format("BlockSync.cellToWorld: missing anchor %s under %s", anchorName, bayModel:GetFullName()))
	end

	return anchor.CFrame
end

local function spawnShockwave(bayModel, worldCFrame, level, color)
	local ring = Instance.new("Part")
	ring.Name = "Shockwave"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.Material = Enum.Material.Neon
	ring.Color = COLOR_RGB[color] or Color3.fromRGB(255, 255, 255)
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.2, 1, 1)
	ring.CFrame = worldCFrame * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = bayModel

	local targetRadius = (level == 2) and 18 or 8
	local tween = TweenService:Create(ring, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, targetRadius, targetRadius),
		Transparency = 1,
	})
	tween:Play()
	Debris:AddItem(ring, 0.5)
end

local function buildCrateModel(color, level)
	local model = Instance.new("Model")
	model.Name = "Crate"

	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.CorrodedMetal
	base.Color = COLOR_RGB[color] or Color3.fromRGB(200, 200, 200)
	base.Size = Vector3.new(4, 4, 4)
	base.Parent = model
	model.PrimaryPart = base

	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Anchored = true
	stripe.CanCollide = false
	stripe.CanQuery = false
	stripe.Material = Enum.Material.Neon
	stripe.Color = COLOR_RGB[color] or Color3.fromRGB(255, 255, 255)
	stripe.Size = Vector3.new(4.05, 0.4, 4.05)
	stripe.Parent = model

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.Parent = base
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = color:upper()
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.SourceSansBold
	label.TextScaled = true
	label.Parent = gui

	if level == 2 then
		local topper = Instance.new("Part")
		topper.Name = "Topper"
		topper.Anchored = true
		topper.CanCollide = true
		topper.Material = Enum.Material.CorrodedMetal
		topper.Color = COLOR_RGB[color] or Color3.fromRGB(200, 200, 200)
		topper.Size = Vector3.new(3, 3, 3)
		topper.Parent = model

		local topperStripe = stripe:Clone()
		topperStripe.Name = "TopperStripe"
		topperStripe.Size = Vector3.new(3.05, 0.3, 3.05)
		topperStripe.Parent = model
	end

	return model
end

local function positionCrate(crateModel, worldCFrame, level)
	local base = crateModel.Base
	base.CFrame = worldCFrame * CFrame.new(0, base.Size.Y / 2, 0)
	crateModel.Stripe.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + 0.05, 0)

	if level == 2 then
		local topper = crateModel:FindFirstChild("Topper")
		if topper then
			topper.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + topper.Size.Y / 2, 0)
			crateModel.TopperStripe.CFrame = topper.CFrame * CFrame.new(0, topper.Size.Y / 2 + 0.05, 0)
		end
	end
end

return BlockSync
