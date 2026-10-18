-- ReplicatedStorage.PatternMatch.Attract
-- Attract mode: a demo loop on the boards while the game is Idle. Run on the server by PatternMatch.Game
-- (start when Idle begins, stop the moment anything else starts), so every player in the room sees the
-- same demo.
--   1. The TargetBoard shows a pattern (Target.generate, 2-4 blocks).
--   2. The LiveBoard places the matching blocks one at a time, Config.attractPlaceInterval apart, each
--      dropping in with a short ease; all bottom blocks first, then the stacked ones on top of them.
--   3. Matched: a short pause, then the shared celebration (PatternMatch.Celebrate, the same one as the
--      shift's ORDER UP): big "COMPLETE!" popping in above the boards, a sparkle burst off both boards,
--      a white flash on the cells and a pop sound. The blocks on both boards pop and shrink away, a gap,
--      and the next pattern.
--   4. Config.attractPatterns patterns per set (at least one with a stack), then a fresh set, forever.
-- A floating sign above the boards reads "Match the target board!" / "Press Play to start".
-- It writes ONLY to the two boards' renderers (TargetBoard, LiveBoard.blocks / BlockPool), its own sign
-- and the celebration effect. It never touches Core.StateStore or anything the game reads, so it
-- can't leak into a match or the bridge. stop() cancels everything at once and clears both boards.
-- Driven by Heartbeat, or by advance(dt) from tests when created with manual = true.

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)
local Target = require(script.Parent.Target)

local SHOW_SECONDS = 0.8   -- target shown, nothing placed yet
local DROP_SECONDS = 0.3   -- one block's drop
local DROP_HEIGHT = 3      -- studs it drops from
local HOLD_SECONDS = 0.6   -- matched, before COMPLETE!
local POP_SECONDS = 0.45   -- blocks pop and shrink away
local GAP_SECONDS = 1.1    -- empty boards before the next pattern (the celebration's 1.5 s ends first)
local SIGN_TEXT = "Match the target board!"
local SIGN_SUBTEXT = "Press Play to start"

local Attract = {}
Attract.__index = Attract
Attract.SHOW_SECONDS, Attract.DROP_SECONDS, Attract.HOLD_SECONDS = SHOW_SECONDS, DROP_SECONDS, HOLD_SECONDS
Attract.POP_SECONDS, Attract.GAP_SECONDS = POP_SECONDS, GAP_SECONDS

local function easeOutBack(t)
	local c = 1.4
	return 1 + (c + 1) * (t - 1) ^ 3 + c * (t - 1) ^ 2
end

-- The floating sign above the boards, made once in the cabinet: an invisible anchor with a BillboardGui.
local function sign(cabinet)
	local anchor = cabinet:FindFirstChild("AttractSign")
	if not anchor then
		local tableTop = cabinet:FindFirstChild("Table") and cabinet.Table:FindFirstChild("Top")
		local at = tableTop and tableTop.Position + Vector3.new(0, 11, -3) or Vector3.new(0, 14, -30)
		anchor = Instance.new("Part")
		anchor.Name = "AttractSign"
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.CFrame = CFrame.new(at)
		anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = true, false, false, false
		anchor.Transparency = 1
		anchor.CastShadow = false

		local gui = Instance.new("BillboardGui")
		gui.Name = "Sign"
		gui.Size = UDim2.fromScale(22, 5)
		gui.LightInfluence = 0
		gui.MaxDistance = 200
		gui.Enabled = false
		gui.Parent = anchor
		local title = Instance.new("TextLabel")
		title.Name = "Title"
		title.BackgroundTransparency = 1
		title.Size = UDim2.fromScale(1, 0.62)
		title.Font = Enum.Font.GothamBlack
		title.TextScaled = true
		title.TextColor3 = Color3.new(1, 1, 1)
		title.Text = SIGN_TEXT
		title.Parent = gui
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Color3.fromRGB(40, 20, 70)
		stroke.Parent = title
		local sub = Instance.new("TextLabel")
		sub.Name = "Subtitle"
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.fromScale(0.15, 0.64)
		sub.Size = UDim2.fromScale(0.7, 0.32)
		sub.Font = Enum.Font.GothamBold
		sub.TextScaled = true
		sub.TextColor3 = Color3.fromRGB(255, 214, 90)
		sub.Text = SIGN_SUBTEXT
		sub.Parent = gui
		local subStroke = stroke:Clone()
		subStroke.Thickness = 2
		subStroke.Parent = sub

		anchor.Parent = cabinet
	end
	return anchor
end

-- opts: cabinet (Workspace.PatternCabinet), targetBoard (PatternMatch.TargetBoard object), liveBoard
-- (PatternMatch.LiveBoard object), celebrate (PatternMatch.Celebrate object), rng (optional Random),
-- manual (true: no Heartbeat, call advance)
function Attract.new(opts)
	local self = setmetatable({}, Attract)
	self.targetBoard = opts.targetBoard
	self.livePool = opts.liveBoard.blocks
	self.targetPool = opts.targetBoard.blocks
	self.rng = opts.rng or Random.new()
	self.manual = opts.manual == true
	self.sign = sign(opts.cabinet)
	self.celebrate = opts.celebrate
	self.running = false
	self.completions = 0 -- patterns finished since the last start (for tests and logs)
	return self
end

-- A fresh set of Config.attractPatterns patterns, 2-4 blocks each, towers up to maxStackGlobal; at least
-- one of them has a stack.
function Attract:newSet()
	local set, anyStack = {}, false
	for i = 1, Config.attractPatterns do
		local n = self.rng:NextInteger(2, 4)
		local target = Target.generate(n, Config.maxStackGlobal, self.rng, 0.35)
		local _, tallest = Target.count(target)
		anyStack = anyStack or tallest > 1
		set[i] = target
	end
	if not anyStack and #set > 0 then
		local i = self.rng:NextInteger(1, #set)
		set[i] = Target.generate(self.rng:NextInteger(2, 4), Config.maxStackGlobal, self.rng, 1)
	end
	return set
end

-- The order blocks go on the LiveBoard: every bottom block (by cell), then every stacked block.
local function placements(target)
	local list = {}
	for cell, tower in pairs(target) do
		for i, color in ipairs(tower) do
			table.insert(list, { cell = cell, level = i - 1, color = color })
		end
	end
	table.sort(list, function(a, b)
		if a.level ~= b.level then return a.level < b.level end
		return a.cell < b.cell
	end)
	return list
end
Attract.placements = placements

function Attract:start()
	if self.running then
		return
	end
	self.running = true
	self.completions = 0
	self.set = self:newSet()
	self.index = 0
	self.sign.Sign.Enabled = true
	self:setSignText(SIGN_TEXT)
	self:nextPattern()
	if not self.manual then
		self.connection = RunService.Heartbeat:Connect(function(dt)
			self:advance(dt)
		end)
	end
end

-- Stops at once: no more timers or animations, both boards cleared (every block hidden, back at its rest
-- place at full size), sparkles off, sign hidden.
function Attract:stop()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	if not self.running then
		return
	end
	self.running = false
	self.anims = {}
	self.phase = nil
	self.targetBoard:show(nil)
	self.targetPool:clear()
	self.livePool:clear()
	self.celebrate:stop()
	self.sign.Sign.Enabled = false
	self:setSignText(SIGN_TEXT)
end

function Attract:setSignText(text)
	local title = self.sign.Sign.Title
	title.Text = text
	title.TextColor3 = text == SIGN_TEXT and Color3.new(1, 1, 1) or Color3.fromRGB(255, 220, 70)
end

function Attract:nextPattern()
	self.index += 1
	if self.index > #self.set then
		self.set = self:newSet()
		self.index = 1
	end
	self.target = self.set[self.index]
	self.order = placements(self.target)
	self.placed = 0
	self.anims = {}
	self.targetPool:clear()
	self.livePool:clear()
	self.targetBoard:show(self.target, false, false)
	self:setPhase("show", SHOW_SECONDS)
end

function Attract:setPhase(name, seconds)
	self.phase = name
	self.phaseLeft = seconds
end

-- Every block shown on a pool, for the pop animation.
local function shownBlocks(pool)
	local list = {}
	for cell, tower in pairs(pool.parts) do
		for level, part in pairs(tower) do
			if part.Transparency == 0 then
				table.insert(list, { cell = cell, level = level })
			end
		end
	end
	return list
end

-- One step of the demo: phase timers, then the block animations.
function Attract:advance(dt)
	if not self.running then
		return
	end
	self.phaseLeft -= dt
	local phase = self.phase
	if phase == "show" and self.phaseLeft <= 0 then
		self:setPhase("place", 0)
	elseif phase == "place" and self.phaseLeft <= 0 then
		if self.placed < #self.order then
			self.placed += 1
			local step = self.order[self.placed]
			self.livePool:set(step.cell, step.level, Config.colors[step.color])
			self.livePool:pose(step.cell, step.level, DROP_HEIGHT, 1)
			table.insert(self.anims, { pool = self.livePool, cell = step.cell, level = step.level, kind = "drop", t = 0 })
			self.phaseLeft = Config.attractPlaceInterval
		else
			self:setPhase("hold", HOLD_SECONDS)
		end
	elseif phase == "hold" and self.phaseLeft <= 0 then
		self.completions += 1
		self.sign.Sign.Enabled = false -- the celebration's big text takes its place
		self.celebrate:burst("COMPLETE!")
		for _, pool in ipairs({ self.targetPool, self.livePool }) do
			for _, block in ipairs(shownBlocks(pool)) do
				table.insert(self.anims, { pool = pool, cell = block.cell, level = block.level, kind = "pop", t = 0 })
			end
		end
		self:setPhase("pop", POP_SECONDS)
		return -- the pop starts counting from the next frame
	elseif phase == "pop" and self.phaseLeft <= 0 then
		self.anims = {}
		self.targetBoard:show(nil)
		self.targetPool:clear()
		self.livePool:clear()
		self:setPhase("gap", GAP_SECONDS)
	elseif phase == "gap" and self.phaseLeft <= 0 then
		self.sign.Sign.Enabled = true
		self:setSignText(SIGN_TEXT)
		self:nextPattern()
	end

	local still = {}
	for _, anim in ipairs(self.anims) do
		anim.t += dt
		if anim.kind == "drop" then
			local k = math.min(1, anim.t / DROP_SECONDS)
			anim.pool:pose(anim.cell, anim.level, DROP_HEIGHT * (1 - easeOutBack(k)), 1)
			if k < 1 then table.insert(still, anim) end
		else -- pop: a quick swell, then shrink to nothing
			local k = math.min(1, anim.t / POP_SECONDS)
			local scale = k < 0.3 and 1 + 0.25 * (k / 0.3) or 1.25 * (1 - (k - 0.3) / 0.7)
			anim.pool:pose(anim.cell, anim.level, 0, math.max(scale, 0.01))
			if k < 1 then table.insert(still, anim) end
		end
	end
	self.anims = still
end

-- Seconds of one pattern from first show to the next pattern's show, for tests and docs.
function Attract.cycleSeconds(blocks)
	return SHOW_SECONDS + blocks * Config.attractPlaceInterval + HOLD_SECONDS + POP_SECONDS + GAP_SECONDS
end

return Attract
