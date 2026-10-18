-- ReplicatedStorage.PatternMatch.Celebrate
-- The shared "you matched it" moment, used by the attract demo's COMPLETE! and the shift's ORDER UP, so
-- both feel the same. Run on the server (PatternMatch.Game owns one); every effect is a replicated
-- instance or property change, so all players see it.
--   burst(text):
--     - a big sparkle burst rising off both boards for about Celebrate.SECONDS (1.5 s): a ParticleEmitter
--       CelebrateSparkle in each board's Base, on for BURST_SECONDS, particles living up to ~1.6 s;
--     - a quick white flash on every board cell (tiles turn white, then ease back to their wood color);
--     - big text above the boards (BillboardGui CelebrateText) that pops in with a scale tween and stays
--       up for Celebrate.SECONDS;
--     - a pop sound.
--   stop(): ends a burst at once (emitters off and cleared, tile colors restored, text hidden).

local TweenService = game:GetService("TweenService")

local SECONDS = 1.5          -- how long the text stays up and the sparkles keep coming
local BURST_SECONDS = 1.2    -- emitters on; the last particles fade out by about SECONDS + 0.4
local FLASH_COLOR = Color3.new(1, 1, 1)
local FLASH_FADE = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local POP_IN = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_SOUND = "rbxasset://sounds/electronicpingshort.wav"

local Celebrate = {}
Celebrate.__index = Celebrate
Celebrate.SECONDS = SECONDS
Celebrate.FLASH_COLOR = FLASH_COLOR

local function emitterOn(base)
	local emitter = base:FindFirstChild("CelebrateSparkle")
	if not emitter then
		emitter = Instance.new("ParticleEmitter")
		emitter.Name = "CelebrateSparkle"
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 228, 110)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 160, 60)),
		})
		emitter.LightEmission = 1
		emitter.LightInfluence = 0
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.8), NumberSequenceKeypoint.new(0.5, 1.2), NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0.2),
			NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.9, 1.6)
		emitter.Speed = NumberRange.new(12, 24)
		emitter.SpreadAngle = Vector2.new(40, 40)
		emitter.Acceleration = Vector3.new(0, -16, 0)
		emitter.Drag = 1.5
		emitter.RotSpeed = NumberRange.new(-180, 180)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Rate = 450
		emitter.Enabled = false
		emitter.Parent = base
	end
	return emitter
end

-- The big text above the boards: an invisible anchor with a BillboardGui, its label, a UIScale for the
-- pop-in, and the pop sound. Made once in the cabinet.
local function textAnchor(cabinet)
	local anchor = cabinet:FindFirstChild("CelebrateText")
	if anchor then
		return anchor
	end
	local tableTop = cabinet:FindFirstChild("Table") and cabinet.Table:FindFirstChild("Top")
	-- Above the boards, a little toward the TargetBoard so the arm twin (on the LiveBoard's apron) doesn't
	-- cut through the text from the player's side.
	local at = tableTop and tableTop.Position + Vector3.new(-4, 11, -3) or Vector3.new(-4, 14, -30)
	anchor = Instance.new("Part")
	anchor.Name = "CelebrateText"
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(at)
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = true, false, false, false
	anchor.Transparency = 1
	anchor.CastShadow = false

	local gui = Instance.new("BillboardGui")
	gui.Name = "Gui"
	gui.Size = UDim2.fromScale(34, 8)
	gui.LightInfluence = 0
	gui.MaxDistance = 250
	gui.Enabled = false
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 220, 70)
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(110, 40, 0)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Parent = label

	local pop = Instance.new("Sound")
	pop.Name = "Pop"
	pop.SoundId = POP_SOUND
	pop.Volume = 0.7
	pop.RollOffMaxDistance = 140
	pop.Parent = anchor
	anchor.Parent = cabinet
	return anchor
end

-- cabinet: Workspace.PatternCabinet; boards: the board Models whose cells flash and whose Base sparkles.
function Celebrate.new(cabinet, boards)
	local self = setmetatable({ emitters = {}, tiles = {}, tweens = {}, threads = {}, generation = 0, active = false }, Celebrate)
	self.anchor = textAnchor(cabinet)
	self.gui = self.anchor.Gui
	self.label = self.gui.Label
	self.scale = self.label.UIScale
	for _, board in ipairs(boards) do
		local base = board:FindFirstChild("Base")
		if base then
			table.insert(self.emitters, emitterOn(base))
		end
		for _, child in ipairs(board:GetChildren()) do
			if child:IsA("BasePart") and string.match(child.Name, "^%u%d+$") then
				table.insert(self.tiles, { part = child, color = child.Color })
			end
		end
	end
	return self
end

function Celebrate:cancelTweens()
	for _, tween in ipairs(self.tweens) do
		tween:Cancel()
	end
	table.clear(self.tweens)
end

-- The matched moment: sparkles, cell flash, big text with a pop-in, pop sound.
function Celebrate:burst(text)
	self:stop()
	self.generation += 1
	local mine = self.generation
	self.active = true

	for _, emitter in ipairs(self.emitters) do
		emitter.Enabled = true
	end
	for _, tile in ipairs(self.tiles) do
		tile.part.Color = FLASH_COLOR
		local tween = TweenService:Create(tile.part, FLASH_FADE, { Color = tile.color })
		table.insert(self.tweens, tween)
		tween:Play()
	end
	self.label.Text = text
	self.scale.Scale = 0.3
	self.gui.Enabled = true
	local pop = TweenService:Create(self.scale, POP_IN, { Scale = 1 })
	table.insert(self.tweens, pop)
	pop:Play()
	local sound = self.anchor:FindFirstChild("Pop")
	if sound then
		sound:Play()
	end

	table.insert(self.threads, task.delay(BURST_SECONDS, function()
		if self.generation == mine then
			for _, emitter in ipairs(self.emitters) do
				emitter.Enabled = false
			end
		end
	end))
	table.insert(self.threads, task.delay(SECONDS, function()
		if self.generation == mine then
			self.gui.Enabled = false
			self.active = false
			self:cancelTweens()
			for _, tile in ipairs(self.tiles) do -- the flash tween has finished by now; make it exact
				tile.part.Color = tile.color
			end
		end
	end))
end

-- Ends any burst now: its timers cancelled, emitters off and cleared, tile colors back, text hidden.
function Celebrate:stop()
	self.generation += 1
	for _, thread in ipairs(self.threads) do
		if coroutine.status(thread) == "suspended" then
			task.cancel(thread)
		end
	end
	table.clear(self.threads)
	self.active = false
	self:cancelTweens()
	for _, emitter in ipairs(self.emitters) do
		emitter.Enabled = false
		emitter:Clear()
	end
	for _, tile in ipairs(self.tiles) do
		if tile.part.Color ~= tile.color then
			tile.part.Color = tile.color
		end
	end
	self.gui.Enabled = false
	self.scale.Scale = 1
end

return Celebrate
