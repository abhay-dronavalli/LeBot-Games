-- BlockSync (Section 7, 10.2 steps 1, 3 & 8) -- nothing else hard-codes world positions;
-- cellToWorld reads the Cell_c_r anchor parts baked into each bay prefab. Also diffs `cells`
-- snapshots per bay and hands the actual crate delivery/removal off to SkyArm, which physically
-- carries each crate into (or out of) its cell (Section 3.2, 5.2).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local SkyArm = require(ServerScriptService:WaitForChild("SkyArm"))

local BlockSync = {}

-- Fired after every applied snapshot with (bayModel, cellsList). HazardManager listens to this
-- to decide whether a bay's obstacle has been solved. One-directional: HazardManager depends
-- on BlockSync, never the other way round.
local cellsChangedEvent = Instance.new("BindableEvent")
BlockSync.CellsChanged = cellsChangedEvent.Event

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

----------------------------------------------------------------
-- Crate spawning / removal (Section 3.2, 5.2)
----------------------------------------------------------------
local lastAppliedByBay = setmetatable({}, {__mode = "k"})
local liveCratesByBay = setmetatable({}, {__mode = "k"})

local function keyFor(c)
	return c.col .. "," .. c.row
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
	-- A rapid colour/level change destroys the old crate while an arm job may still hold a
	-- reference to it, so every late callback has to tolerate a dead model.
	local base = crateModel and crateModel.Parent and crateModel:FindFirstChild("Base")
	if not base then
		return
	end
	base.CFrame = worldCFrame * CFrame.new(0, base.Size.Y / 2, 0)
	local stripe = crateModel:FindFirstChild("Stripe")
	if stripe then
		stripe.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + 0.05, 0)
	end

	if level == 2 then
		local topper = crateModel:FindFirstChild("Topper")
		if topper then
			topper.CFrame = base.CFrame * CFrame.new(0, base.Size.Y / 2 + topper.Size.Y / 2, 0)
			local topperStripe = crateModel:FindFirstChild("TopperStripe")
			if topperStripe then
				topperStripe.CFrame = topper.CFrame * CFrame.new(0, topper.Size.Y / 2 + 0.05, 0)
			end
		end
	end
end

----------------------------------------------------------------
-- Placement guards
--
-- An obstacle can refuse deliveries into its own bay -- the saw wall turns away crates dropped
-- in front of live blades, because stalling the wall is meant to be a reward for killing them
-- first. HazardManager registers the guard, so the dependency still only points one way.
--
-- A refusal is not a discard: the operator's cube is still sitting on the real table, so the
-- game owes them that crate the moment the guard changes its mind. Rejects are parked per bay
-- and retryRejected() delivers them.
----------------------------------------------------------------
local placementGuards = setmetatable({}, {__mode = "k"})
local rejectedByBay = setmetatable({}, {__mode = "k"})

local rejectedEvent = Instance.new("BindableEvent")
BlockSync.PlacementRejected = rejectedEvent.Event

function BlockSync.setPlacementGuard(bayModel, fn)
	placementGuards[bayModel] = fn
end

local function allowed(bayModel, cell)
	local guard = placementGuards[bayModel]
	if not guard then
		return true
	end
	return guard(cell)
end

local function liveTableFor(bayModel)
	local live = liveCratesByBay[bayModel]
	if not live then
		live = {}
		liveCratesByBay[bayModel] = live
	end
	return live
end

local function deliver(bayModel, live, key, cell)
	local worldCFrame = BlockSync.cellToWorld(bayModel, cell.col, cell.row)
	local crateModel = buildCrateModel(cell.color, cell.level)
	live[key] = crateModel
	SkyArm.reachAndPlace(bayModel, worldCFrame, crateModel, cell.level, function()
		if not crateModel.Parent then
			return -- superseded by a newer edit while the arm was in flight
		end
		positionCrate(crateModel, worldCFrame, cell.level)
		spawnShockwave(bayModel, worldCFrame, cell.level, cell.color)
	end)
end

-- Re-offer everything a guard turned away earlier, for whichever cells it now accepts.
function BlockSync.retryRejected(bayModel)
	local rej = rejectedByBay[bayModel]
	if not rej then
		return
	end
	local live = liveTableFor(bayModel)
	for key, cell in pairs(rej) do
		if allowed(bayModel, cell) then
			rej[key] = nil
			deliver(bayModel, live, key, cell)
		end
	end
end

----------------------------------------------------------------
-- Public: diff + apply a new `cells` snapshot for a given bay (Section 5.2)
----------------------------------------------------------------
function BlockSync.applyCells(bayModel, newCellsList)
	local last = lastAppliedByBay[bayModel] or {}
	local live = liveTableFor(bayModel)

	local newByKey = {}
	for _, c in ipairs(newCellsList) do
		newByKey[keyFor(c)] = c
	end

	-- Removed cells: wait 0.4s, then have the arm lift the crate out (Section 5.2.3)
	for key, oldCell in pairs(last) do
		if not newByKey[key] then
			local crateModel = live[key]
			live[key] = nil
			-- lifting the cube off the table voids any rejection parked for that cell
			local rej = rejectedByBay[bayModel]
			if rej then
				rej[key] = nil
			end
			task.delay(Config.CrateRemoveDelay, function()
				if crateModel and crateModel.Parent then
					local worldCFrame = BlockSync.cellToWorld(bayModel, oldCell.col, oldCell.row)
					SkyArm.reachAndRemove(bayModel, worldCFrame, crateModel)
				end
			end)
		end
	end

	-- Added / changed cells: wait 0.2s, then have the arm deliver (or swap) the crate (Section 5.2.2, 5.2.4)
	for key, newCell in pairs(newByKey) do
		local oldCell = last[key]
		local isNew = not oldCell
		local isChanged = oldCell and (oldCell.level ~= newCell.level or oldCell.color ~= newCell.color)
		if isNew or isChanged then
			task.delay(Config.CrateConfirmDelay, function()
				local existing = live[key]
				if existing then
					-- A crate still waiting its turn in the arm queue has no Parent yet, so
					-- `.Parent` cannot tell "not placed yet" from "already destroyed" -- and
					-- the old check skipped exactly the queued ones, so fast colour cycling
					-- left several crates stacked in one cell. Flag it instead and let
					-- whichever side reaches it first do the cleanup.
					existing:SetAttribute("Superseded", true)
					if existing.Parent then
						existing:Destroy()
					end
				end

				local ok, reason = allowed(bayModel, newCell)
				if not ok then
					-- park it; the cube is still on the real table, so this is deferred
					local rej = rejectedByBay[bayModel]
					if not rej then
						rej = {}
						rejectedByBay[bayModel] = rej
					end
					rej[key] = newCell
					live[key] = nil
					rejectedEvent:Fire(bayModel, newCell, reason)
					return
				end

				deliver(bayModel, live, key, newCell)
			end)
		end
	end

	lastAppliedByBay[bayModel] = newByKey
	cellsChangedEvent:Fire(bayModel, newCellsList)
end

return BlockSync
