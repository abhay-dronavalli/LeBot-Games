-- BlockSync (Section 7, 10.2 steps 1, 3 & 8) -- nothing else hard-codes world positions;
-- cellToWorld reads the Cell_c_r anchor parts baked into each bay prefab.
--
-- TWO INPUT PATHS, never both at once:
--
--   applyCells(bay, cells)   the solo/DebugMode path. Diffs `cells` snapshots and hands crate
--                            delivery to SkyArm, which animates a reach into the cell.
--   applyBlocks(bay, blocks) the LIVE path (robot-link.md). One crate per real cube, tracked
--                            by block id and positioned every frame. No delivery animation:
--                            player 2's real carry motion already is one.
--
-- Both end at the same cellsChangedEvent, so HazardManager cannot tell them apart and the
-- placement guards work for either.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Mapping = require(ReplicatedStorage:WaitForChild("Mapping"))
local SkyArm = require(ServerScriptService:WaitForChild("SkyArm"))

local BlockSync = {}

-- Fired after every applied snapshot with (bayModel, cellsList). HazardManager listens to this
-- to decide whether a bay's obstacle has been solved. One-directional: HazardManager depends
-- on BlockSync, never the other way round.
local cellsChangedEvent = Instance.new("BindableEvent")
BlockSync.CellsChanged = cellsChangedEvent.Event

-- Fired when a crate has physically SEATED in its cell. Deliberately distinct from
-- CellsChanged, which fires as soon as the snapshot changes -- at that point the arm still has
-- ~5s of carry to do, and the crate may not arrive at all, because a placement guard can
-- refuse it. Anything whose timing or safety depends on the crate actually BEING there has to
-- listen to this one: bay 3 starts its cooldown from it, and treating the snapshot as arrival
-- there marked a refused cell safe to stand on.
local cratePlacedEvent = Instance.new("BindableEvent")
BlockSync.CratePlaced = cratePlacedEvent.Event

local COLOR_RGB = {
	red = Color3.fromRGB(210, 50, 50),
	blue = Color3.fromRGB(60, 150, 220),
	yellow = Color3.fromRGB(225, 200, 50),
	green = Color3.fromRGB(70, 190, 90),
	orange = Color3.fromRGB(230, 130, 30),
	purple = Color3.fromRGB(150, 80, 200),
	teal = Color3.fromRGB(50, 190, 180),
}

-- How far a bay sinks its crates below the floor plane.
--
-- Normally a crate rests ON the floor: you climb it, and its top is a cube above where you
-- walk. In a bay where the crates ARE the floor -- the void -- that is wrong: the bridge ends
-- up a cube proud of the walkway, so crossing means hopping up onto every slab and back down.
-- Such a bay sets CrateSink on its model and the crates drop to sit flush.
local function sinkFor(bayModel)
	return tonumber(bayModel and bayModel:GetAttribute("CrateSink")) or 0
end

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

	return anchor.CFrame * CFrame.new(0, -sinkFor(bayModel), 0)
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

-- ONE crate size for both paths.
--
-- This built a 4 stud Base with a 3 stud Topper, from when a crate was a prop rather than a
-- cube. The live path builds real 6.72 stud cubes (Mapping.cubeStuds, from the 48 mm cube at
-- the mat-to-bay scale), and bay 1's lever gate is tuned to those heights -- so solo play had
-- crates topping out at 4.00 and 7.00 against a gate wanting 6.72 and 13.44. Lever A squeaked
-- through on tolerance and **Lever B could never be thrown at all**: the bay was unsolvable
-- unless the real robot was driving it.
--
-- A level-2 crate is now two identical cubes, which is what the real table has.
local function buildCrateModel(color, level)
	local w = Mapping.cubeStuds()
	local model = Instance.new("Model")
	model.Name = "Crate"

	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.CorrodedMetal
	base.Color = COLOR_RGB[color] or Color3.fromRGB(200, 200, 200)
	base.Size = Vector3.new(w, w, w)
	base.Parent = model
	base:SetAttribute("IsCrate", true)
	model.PrimaryPart = base

	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Anchored = true
	stripe.CanCollide = false
	stripe.CanQuery = false
	stripe.Material = Enum.Material.Neon
	stripe.Color = COLOR_RGB[color] or Color3.fromRGB(255, 255, 255)
	stripe.Size = Vector3.new(w * 1.01, w * 0.09, w * 1.01)
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
		-- the same cube again, not a smaller cap: two cubes stacked is what level 2 means
		topper.Size = Vector3.new(w, w, w)
		topper.Parent = model
		topper:SetAttribute("IsCrate", true)

		local topperStripe = stripe:Clone()
		topperStripe.Name = "TopperStripe"
		topperStripe.Size = Vector3.new(w * 1.01, w * 0.08, w * 1.01)
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

-- VIRTUAL CRATES. In some bays the cube is a TOKEN, not an object.
--
-- The laser walk is the case: the operator moves a real cube across the real mat and what
-- that does in here is disarm the matching tile. The player walks on the floor -- the pad is
-- the authoritative killer, and a safe pad does not kill -- so a crate standing in the cell
-- was never load-bearing. It was scenery, and scenery that reads as "climb me" in a bay where
-- climbing is not the point.
--
-- The cell bookkeeping is unchanged: CellsChanged and CratePlaced still fire, so solve
-- detection and the cooldown that lets you walk to the next tile work exactly as before.
local function deliver(bayModel, live, key, cell)
	local worldCFrame = BlockSync.cellToWorld(bayModel, cell.col, cell.row)

	if bayModel:GetAttribute("VirtualCrates") then
		live[key] = nil
		spawnShockwave(bayModel, worldCFrame, cell.level, cell.color)
		-- no arm trip and no model: nothing is carried in, the tile just goes quiet
		task.defer(function()
			cratePlacedEvent:Fire(bayModel, cell)
		end)
		return
	end

	local crateModel = buildCrateModel(cell.color, cell.level)
	live[key] = crateModel
	SkyArm.reachAndPlace(bayModel, worldCFrame, crateModel, cell.level, function()
		if not crateModel.Parent then
			return -- superseded by a newer edit while the arm was in flight
		end
		positionCrate(crateModel, worldCFrame, cell.level)
		spawnShockwave(bayModel, worldCFrame, cell.level, cell.color)
		cratePlacedEvent:Fire(bayModel, cell)
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

----------------------------------------------------------------
-- The live path: one crate per real cube (robot-link.md)
--
-- The wire carries `blocks`, not `cells`: one entry per physical cube, with a stable id, a
-- stack `level` that is 0 on the paper, and `held` while it is in the jaw. Cells are a derived
-- view, computed here so HazardManager's solve logic is untouched.
--
-- Nothing here animates a delivery. The obby's SkyArm exists to *simulate* an operator; there
-- is a real one now, and re-enacting a reach they already made with their hands is the one
-- thing that must never happen. The carry animation comes free instead: a held cube follows
-- the jaw, so the operator's real motion is the crate's flight path.
----------------------------------------------------------------

-- The perception palette has nine names against the obby's seven, and identity comes from
-- `id`, not colour -- PROTOCOL.md is explicit that a wrong colour is cosmetic. Collapse the
-- two strays onto their nearest obby colour rather than dropping the cube: a crate of the
-- wrong colour is still footing, which is what Bay 1 actually needs.
local COLOR_ALIAS = {
	["light blue"] = "blue",   -- hue 250 vs blue's 268; the kit's own near-miss
	pink = "red",
	grey = "grey",             -- what a held cube reports; see PROTOCOL.md
}

local GREY = Color3.fromRGB(154, 164, 178)
local LOST_TRANSPARENCY = 0.6     -- the camera cannot see this cube right now

local function obbyColor(name)
	name = tostring(name or "grey")
	return COLOR_ALIAS[name] or name
end

-- One cube, as one welded assembly so a constraint can carry it with a player aboard.
--
-- Named Base because HazardManager's reach gating raycasts for a part called Base or Topper;
-- it also carries an IsCrate attribute so that check can stop depending on names. Every live
-- cube is identical, so there is no Topper here -- a stack is two cubes, which is what the
-- real table has, and lifting the top one drops the stack to L1 with no special case.
local function buildCube(colorName)
	local w = Mapping.cubeStuds()
	local model = Instance.new("Model")
	model.Name = "Crate"

	local base = Instance.new("Part")
	base.Name = "Base"
	base.Anchored = true
	base.CanCollide = true
	base.Material = Enum.Material.CorrodedMetal
	base.Color = COLOR_RGB[obbyColor(colorName)] or GREY
	base.Size = Vector3.new(w, w, w)
	base.CustomPhysicalProperties = PhysicalProperties.new(0.7, 1.0, 0, 100, 100) -- grippy underfoot
	base.Parent = model
	base:SetAttribute("IsCrate", true)
	model.PrimaryPart = base

	-- The stripe must NOT be anchored in its own right. A WeldConstraint makes these two parts
	-- one assembly, and an assembly containing any anchored part has infinite mass -- so
	-- unanchoring the base for a carry still left the cube immovable and AlignPosition drove it
	-- nowhere, with the goal sitting correctly at the jaw the whole time. Anchoring the base
	-- alone is what holds the pair still while it rests.
	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Anchored = false
	stripe.CanCollide = false
	stripe.CanQuery = false
	stripe.Massless = true           -- decoration; it must not change how the cube carries
	stripe.Material = Enum.Material.Neon
	stripe.Color = base.Color
	stripe.Size = Vector3.new(w * 1.01, w * 0.09, w * 1.01)
	stripe.CFrame = base.CFrame      -- a band round the cube's equator; set before the weld,
	stripe.Parent = model            -- because the weld freezes whatever offset it finds

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = base
	weld.Part1 = stripe
	weld.Parent = base

	local att = Instance.new("Attachment")
	att.Name = "Drive"
	att.Parent = base

	local goal = Instance.new("Attachment")
	goal.Name = "Goal"
	goal.Parent = workspace.Terrain      -- world-anchored, so there is something to drive toward

	-- AlignPosition.MaxForce defaults to 10000. A 6.7 stud cube at density 0.7 weighs far more
	-- than that under default gravity, and an under-powered constraint cannot hold the part up
	-- at all: it sags, and a carried one sinks through the world until the engine destroys it
	-- at FallenPartsDestroyHeight, losing the cube for the session. The rider speed cap lives
	-- in MaxVelocity, where it belongs, so raising these costs nothing in safety.
	local pos = Instance.new("AlignPosition")
	pos.Attachment0, pos.Attachment1 = att, goal
	pos.MaxForce, pos.MaxVelocity, pos.Responsiveness = 1e8, 60, 40
	pos.ApplyAtCenterOfMass = true
	pos.Parent = base

	local rot = Instance.new("AlignOrientation")
	rot.Attachment0, rot.Attachment1 = att, goal
	rot.MaxTorque, rot.Responsiveness = 1e8, 40
	rot.Parent = base

	return {model = model, base = base, stripe = stripe, goal = goal}
end

local liveBlocksByBay = setmetatable({}, {__mode = "k"})
local refusedByBay = setmetatable({}, {__mode = "k"})
local lastLiveSignature = setmetatable({}, {__mode = "k"})
-- held-last flags for virtual bays, which have no cube entry to hang them on
local entryHeldLast = {}

local function destroyCube(entry)
	entry.goal:Destroy()
	entry.model:Destroy()
end

-- Group cubes into the one-colour-per-cell view the solve logic wants. A cell's colour is the
-- BOTTOM cube's: the obby's model is one colour per cell and the wire's is one entry per cube,
-- so a mixed-colour stack is simply not representable. Level is the tallest cube in the cell,
-- +1 because the wire counts from 0 and the obby counts from 1, clamped at 2 because the real
-- table only has two cubes of a colour and three-high does not exist.
local function cellsFromBlocks(placed)
	local byCell = {}
	for _, p in ipairs(placed) do
		local key = p.col .. "," .. p.row
		local cell = byCell[key]
		if not cell then
			byCell[key] = {col = p.col, row = p.row, color = p.color, level = p.level + 1,
				bottom = p.level}
		else
			if p.level < cell.bottom then
				cell.bottom, cell.color = p.level, p.color
			end
			cell.level = math.max(cell.level, p.level + 1)
		end
	end
	local list = {}
	for _, cell in pairs(byCell) do
		cell.level = math.min(cell.level, 2)
		cell.bottom = nil
		table.insert(list, cell)
	end
	table.sort(list, function(a, b)
		if a.col == b.col then return a.row < b.row end
		return a.col < b.col
	end)
	return list
end

-- Wipe every crate out of a bay and forget all per-bay bookkeeping, so the next snapshot from
-- either path starts from nothing. This is what "fresh state" means for crates: without it a
-- rebuilt bay keeps the crates of the run before it, and the diff state still believes they
-- are there, so re-placing the same cube is a no-op and the bay looks broken.
function BlockSync.clearBay(bayModel)
	local live = liveBlocksByBay[bayModel]
	if live then
		for id, entry in pairs(live) do
			destroyCube(entry)
			live[id] = nil
		end
	end
	local crates = liveCratesByBay[bayModel]
	if crates then
		for key, model in pairs(crates) do
			if model and model.Parent then
				model:Destroy()
			end
			crates[key] = nil
		end
	end
	-- Anything the arm is still carrying belongs to the run that just ended.
	for _, child in ipairs(bayModel:GetChildren()) do
		if child:IsA("Model") and child.Name == "Crate" then
			child:Destroy()
		end
	end
	lastAppliedByBay[bayModel] = nil
	lastLiveSignature[bayModel] = nil
	rejectedByBay[bayModel] = nil
	refusedByBay[bayModel] = nil
	cellsChangedEvent:Fire(bayModel, {})
end

-- Apply one `blocks` frame to a bay. Safe to call at the wire's 30 Hz: everything is a
-- position update after the first frame.
function BlockSync.applyBlocks(bayModel, blocks)
	if type(blocks) ~= "table" then
		return
	end
	local live = liveBlocksByBay[bayModel]
	if not live then
		live = {}
		liveBlocksByBay[bayModel] = live
	end
	local refused = refusedByBay[bayModel]
	if not refused then
		refused = {}
		refusedByBay[bayModel] = refused
	end

	local w = Mapping.cubeStuds()
	local seen, placed = {}, {}

	for _, b in ipairs(blocks) do
		local col, row = Mapping.cellOf(b.x, b.y)
		local level = b.level or 0

		-- A cube in the tray, or on the bare mat, is not in the bay. A held one is, wherever
		-- the jaw has got to.
		local wanted = b.held or (col ~= nil)

		-- Guards refuse a *placement*, never a carry: the saw wall turns away a crate dropped
		-- in front of live blades, but the operator may still fly one over. Re-checked every
		-- frame, so a parked cube materialises the instant the guard relents -- the live path
		-- needs no retryRejected, it self-heals at 30 Hz.
		local refusalReason = nil
		if wanted and not b.held then
			local ok, reason = allowed(bayModel, {col = col, row = row,
				color = obbyColor(b.color), level = math.min(level + 1, 2)})
			if not ok then
				wanted, refusalReason = false, reason
			end
		end

		-- Edge-triggered, or the HUD would flash the refusal 30 times a second.
		if refusalReason and not refused[b.id] then
			rejectedEvent:Fire(bayModel, {col = col, row = row,
				color = obbyColor(b.color), level = level + 1}, refusalReason)
		end
		refused[b.id] = refusalReason ~= nil or nil

		if not wanted then
			if live[b.id] then
				destroyCube(live[b.id])
				live[b.id] = nil
			end
		else
			-- A virtual-crate bay tracks the cell but never builds the cube (see deliver).
			if bayModel:GetAttribute("VirtualCrates") then
				if live[b.id] then
					destroyCube(live[b.id])
					live[b.id] = nil
				end
				seen[b.id] = true
				if not b.held then
					table.insert(placed, {col = col, row = row,
						color = obbyColor(b.color), level = level})
					if entryHeldLast[b.id] then
						cratePlacedEvent:Fire(bayModel, {col = col, row = row,
							color = obbyColor(b.color), level = math.min(level + 1, 2)})
					end
				end
				entryHeldLast[b.id] = b.held and true or nil
				continue
			end

			seen[b.id] = true
			local entry, fresh = live[b.id], false
			-- Rebuild a cube whose part has left the tree, or one lost cube is permanent:
			-- `seen` keeps the cleanup below from clearing it and it is never recreated.
			if entry == nil or entry.base.Parent == nil then
				if entry then
					destroyCube(entry)
				end
				entry = buildCube(b.color)
				entry.model.Parent = bayModel
				live[b.id] = entry
				fresh = true
			end

			local target
			if b.held then
				-- The real carry height is the whole point, so use the measured pose.
				target = CFrame.new(Mapping.blockPosition(b)) * Mapping.blockOrientation(b)
			else
				-- Resting cubes come off the BAKED anchor, not a scaled millimetre position:
				-- the anchors are the single source of truth for where a cell is, and the
				-- robot has already snapped the cube to its cell centre.
				target = BlockSync.cellToWorld(bayModel, col, row)
					* CFrame.new(0, level * w + w / 2, 0)
			end
			entry.goal.CFrame = target
			if fresh then
				-- A cube built mid-carry would otherwise start at the origin and be hauled
				-- across the map by the constraint. Place it where it already is first.
				entry.base.CFrame = target
			end

			-- Anchored while resting, unanchored while carried.
			--
			-- A resting cube should be exactly where the robot says it is, full stop. Left
			-- unanchored, two stacked cubes are two constraint-driven rigid bodies pressing on
			-- each other and the smallest overlap topples the top one -- a stack that is
			-- perfectly stable on the real table falls over here.
			--
			-- A carried cube is why the part is unanchored at all: an anchored part moved by
			-- CFrame does not carry a player standing on it, and being carried IS the lift.
			-- The goal is kept in sync either way, so the hand-off never jumps.
			-- A cube that was being carried and is now resting has just SEATED. Bay 3 starts
			-- its safe-cell cooldown from this, so the live path has to fire it too -- the
			-- applyCells path fires it from deliver(), and without this a bay timing off
			-- CratePlaced would simply never tick once the real arm is the source.
			local wasHeld = entry.heldLast
			entry.heldLast = b.held and true or nil

			if b.held then
				if entry.base.Anchored then
					-- Start the carry from where the cube already is, so the constraint eases
					-- it off the table instead of dragging it across the map from wherever the
					-- part happened to be built.
					entry.base.Anchored = false
					-- The server must own a carried cube or the rider's own client fights the
					-- server over where it is. Errors on an anchored part, hence the ordering.
					pcall(function()
						entry.base:SetNetworkOwner(nil)
					end)
				end
			else
				entry.base.Anchored = true
				entry.base.CFrame = target
			end

			-- A held cube stays solid: riding it is the whole feature, and the speed cap in
			-- MaxVelocity is what keeps the rider safe, not loss of collision.
			entry.base.CanCollide = true
			entry.base.Transparency = (b.visible or b.held) and 0 or LOST_TRANSPARENCY
			entry.stripe.Transparency = entry.base.Transparency

			-- Colour is refreshed every frame, not just at create: a cube reports grey while in
			-- the jaw and its own colour again on release, so a part coloured once would keep
			-- whatever it was when it first appeared.
			local c = COLOR_RGB[obbyColor(b.color)] or GREY
			entry.base.Color, entry.stripe.Color = c, c

			if not b.held then
				table.insert(placed, {col = col, row = row,
					color = obbyColor(b.color), level = level})
				if wasHeld then
					cratePlacedEvent:Fire(bayModel, {col = col, row = row,
						color = obbyColor(b.color), level = math.min(level + 1, 2)})
				end
			end
		end
	end

	-- A cube taken off the table stops being a crate. The tracker only drops an id after it has
	-- been gone for seconds, so this is never a dropped camera frame.
	for id, entry in pairs(live) do
		if not seen[id] then
			destroyCube(entry)
			live[id] = nil
			refused[id] = nil
		end
	end

	local cells = cellsFromBlocks(placed)

	-- Positions update at the wire's 30 Hz, but the *cell* view changes only when a cube is
	-- set down or lifted. Firing every frame would re-run every bay's solve check thirty times
	-- a second and strobe the labels HazardManager drives off it, so fire on change only.
	local sig = {}
	for _, c in ipairs(cells) do
		table.insert(sig, ("%d,%d,%s,%d"):format(c.col, c.row, c.color, c.level))
	end
	sig = table.concat(sig, ";")
	if sig ~= lastLiveSignature[bayModel] then
		lastLiveSignature[bayModel] = sig
		lastAppliedByBay[bayModel] = nil     -- the two paths must not share diff state
		cellsChangedEvent:Fire(bayModel, cells)
	end
	return cells
end

return BlockSync
