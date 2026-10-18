--!strict
-- The arena HUD's shared widgets: what the player's screen and the dragon operator's screen both
-- show. Views.PlayerView adds the ability bar on top; Views.RobotView adds the operator text, the
-- aiming readout and the "waiting for the arena" card.
--
-- Layout follows concepts/refs/slam.png: survivors pill top left, timer top centre with the active
-- effect chips under it. Banners come and go in the centre. Nothing else stays on screen - the
-- scene behind it is busy, and the dragon is the thing to watch.
--
-- THE HUD DECIDES NOTHING. Every number here arrives in the Hud payload from the server. The timer
-- is not counted locally, and the effect chips show `state.effects[].remaining` - the server's
-- clamped value - because a HUD running its own timer drifts and then lies about a debuff that
-- already ended (hard rule 4).
--
-- A Hud is built by a view's enter() and destroyed by its exit(); nothing here connects to a
-- signal on its own. The view owns every connection and calls Hud.step once a frame, which is
-- where the viewport fit and the timer pulse live. Doing those per frame rather than off
-- ViewportSize signals means a replaced CurrentCamera cannot leave a stale connection behind.
--
--   local hud = Hud.new("ArenaHud")
--   Hud.apply(hud, payload)        -- on every Remotes.Hud payload
--   Hud.banner(hud, info)          -- on every Remotes.Banner
--   Hud.step(hud)                  -- once a frame
--   Hud.destroy(hud)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Arena = ReplicatedStorage:WaitForChild("Arena")
local Theme = require(Arena:WaitForChild("Theme"))
local Icons = require(Arena:WaitForChild("Icons"))

local C = Theme.Color

local Hud = {}

-- The remotes the views use, by name (the same list as Remotes.lua). Remotes.lua waits on these
-- without a timeout, so the views only require it once every one already exists
-- (Hud.awaitRemotes) - a view's enter() runs synchronously inside RoleClient and must never block
-- on the server.
local REMOTE_NAMES = { "Hud", "Banner", "Shake", "SlotFire" }

-- Every text element gets an ink stroke: the scene behind it is lava and fire, and unstroked white
-- text disappears over the bright parts.
local function stroke(label: TextLabel, thickness: number?)
	local s = Instance.new("UIStroke")
	s.Color = C.UiInk
	s.Thickness = thickness or 2
	s.Parent = label
end

function Hud.text(parent: Instance, font: Font, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.TextSize = size
	l.TextColor3 = color
	l.Parent = parent
	stroke(l, size > 40 and 3 or 2)
	return l
end

function Hud.panel(parent: Instance): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = C.UiInk
	f.BackgroundTransparency = 0.35
	f.BorderSizePixel = 0
	f.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = f
	return f
end

-- Builds the shared widgets into a new ScreenGui under PlayerGui. Returned Enabled = false: the
-- view decides when it is shown (the player's HUD only while they are in the round).
function Hud.new(name: string): any
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false

	-- Small screens. Everything below is laid out at desktop sizes and then scaled as one, so the
	-- proportions survive a phone instead of each element needing its own breakpoint. The scale
	-- has a floor, and the player's ability slots have their own minimum, because a slot that
	-- scales down past about 56 px stops being tappable.
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = gui

	-- Top left: survivors.
	local survivorsPill = Hud.panel(gui)
	survivorsPill.Name = "Survivors"
	survivorsPill.Position = UDim2.new(0, 16, 0, 16)
	survivorsPill.Size = UDim2.new(0, 150, 0, 48)

	local survivorsLabel = Hud.text(survivorsPill, Theme.Font.Label, 16, C.UiText)
	survivorsLabel.Position = UDim2.new(0, 12, 0, 6)
	survivorsLabel.Size = UDim2.new(1, -24, 0, 16)
	survivorsLabel.TextXAlignment = Enum.TextXAlignment.Left
	survivorsLabel.Text = "SURVIVORS"

	local survivorsCount = Hud.text(survivorsPill, Theme.Font.Display, 20, C.UiText)
	survivorsCount.Position = UDim2.new(0, 12, 0, 24)
	survivorsCount.Size = UDim2.new(1, -24, 0, 20)
	survivorsCount.TextXAlignment = Enum.TextXAlignment.Left
	survivorsCount.Text = "0/0"

	-- Top centre: the timer and the active effect chips.
	local timer = Hud.text(gui, Theme.Font.Display, 48, C.UiText)
	timer.Name = "Timer"
	timer.AnchorPoint = Vector2.new(0.5, 0)
	timer.Position = UDim2.new(0.5, 0, 0, 10)
	timer.Size = UDim2.new(0, 200, 0, 56)
	timer.Text = "0:00"

	local chipRow = Instance.new("Frame")
	chipRow.Name = "Chips"
	chipRow.BackgroundTransparency = 1
	chipRow.AnchorPoint = Vector2.new(0.5, 0)
	chipRow.Position = UDim2.new(0.5, 0, 0, 68)
	chipRow.Size = UDim2.new(0, 460, 0, 28)
	chipRow.Parent = gui

	local chipLayout = Instance.new("UIListLayout")
	chipLayout.FillDirection = Enum.FillDirection.Horizontal
	chipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	chipLayout.Padding = UDim.new(0, 6)
	chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipLayout.Parent = chipRow

	-- Centre: banners.
	local banner = Hud.text(gui, Theme.Font.Display, 96, C.UiText)
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.new(0.5, 0, 0.38, 0)
	banner.Size = UDim2.new(1, -40, 0, 110)
	banner.Text = ""
	-- Scaled, with a ceiling: "THE DRAGON WINS" at a fixed 96 px runs off the side of a phone, and
	-- TextScaled alone would blow a short word like "3" up to fill the whole band.
	banner.TextScaled = true
	local bannerMax = Instance.new("UITextSizeConstraint")
	bannerMax.MaxTextSize = 96
	bannerMax.MinTextSize = 28
	bannerMax.Parent = banner

	local bannerSub = Hud.text(gui, Theme.Font.Label, 20, C.UiText)
	bannerSub.Name = "BannerSub"
	bannerSub.AnchorPoint = Vector2.new(0.5, 0.5)
	bannerSub.Position = UDim2.new(0.5, 0, 0.38, 70)
	bannerSub.Size = UDim2.new(1, -40, 0, 26)
	bannerSub.Text = ""

	-- Bottom centre: who a dead player is watching.
	local spectating = Hud.text(gui, Theme.Font.Label, 16, C.UiText)
	spectating.Name = "Spectating"
	spectating.AnchorPoint = Vector2.new(0.5, 1)
	spectating.Position = UDim2.new(0.5, 0, 1, -12)
	spectating.Size = UDim2.new(0, 400, 0, 20)
	spectating.Text = ""

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	return {
		gui = gui,
		uiScale = uiScale,
		survivorsPill = survivorsPill,
		survivorsCount = survivorsCount,
		timer = timer,
		chipRow = chipRow,
		banner = banner,
		bannerSub = bannerSub,
		spectating = spectating,
		bannerToken = 0,
		timerUrgent = false,
		viewport = Vector2.zero,
		-- Called after the scale changes, so a view can resize its own widgets against it (the
		-- player's ability slots keep their touch-target floor this way).
		onFit = nil :: ((number) -> ())?,
	}
end

-- One chip per active effect: icon, seconds remaining, border in the effect's colour. Rebuilt from
-- the payload each tick rather than diffed - at most six chips, so the churn is not worth the
-- bookkeeping.
local function drawChips(hud: any, effects: { any })
	for _, child in hud.chipRow:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for i, e in effects do
		local chip = Hud.panel(hud.chipRow)
		chip.Size = UDim2.new(0, 96, 1, 0)
		chip.LayoutOrder = i
		local border = Instance.new("UIStroke")
		border.Color = e.color
		border.Thickness = 2
		border.Parent = chip

		local icon = Icons.draw(chip, e.name, e.color)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 5, 0.5, 0)
		icon.Size = UDim2.new(0, 20, 0, 20)

		local label = Hud.text(chip, Theme.Font.Label, 13, e.color)
		label.Position = UDim2.new(0, 30, 0, 0)
		label.Size = UDim2.new(1, -36, 1, 0)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = ("%s %ds"):format(e.label, math.ceil(e.remaining))
	end
end

-- Survivors, timer, chips and the spectate line, from one Hud payload.
function Hud.apply(hud: any, payload: any)
	hud.spectating.Text = payload.spectating and ("SPECTATING " .. string.upper(payload.spectating)) or ""

	hud.survivorsCount.Text = ("%d/%d"):format(payload.survivors or 0, payload.total or 0)

	local left = payload.timeLeft or 0
	hud.timer.Text = ("%d:%02d"):format(math.floor(left / 60), math.floor(left % 60))
	-- The pulse itself runs in Hud.step. Driving it from here would step it at the payload rate
	-- (8 Hz), which reads as a stutter rather than a pulse.
	hud.timerUrgent = left <= 10 and payload.state == "Round"
	hud.timer.TextColor3 = hud.timerUrgent and C.UiDanger or C.UiText
	if not hud.timerUrgent then
		hud.timer.TextTransparency = 0
	end

	drawChips(hud, payload.effects or {})
end

-- One-off centre text: countdown, round end, debuff toast. A newer banner replaces an older one,
-- and the older one's timeout must not then clear it - hence the token.
function Hud.banner(hud: any, info: any)
	hud.bannerToken += 1
	local mine = hud.bannerToken
	hud.banner.Text = info.text or ""
	hud.banner.TextColor3 = info.color or C.UiText
	hud.bannerSub.Text = info.sub or ""
	task.delay(info.seconds or 2, function()
		-- Destroy() leaves the label's Parent nil, so a banner that outlives its view does nothing.
		if hud.bannerToken == mine and hud.banner.Parent then
			hud.banner.Text = ""
			hud.bannerSub.Text = ""
		end
	end)
end

-- Once a frame: refit to the viewport if it changed, and pulse the timer in its last ten seconds.
function Hud.step(hud: any)
	local camera = workspace.CurrentCamera
	if camera and camera.ViewportSize ~= hud.viewport then
		hud.viewport = camera.ViewportSize
		local v = hud.viewport
		-- 1280 wide is the layout's reference width. Narrower screens shrink, wider ones do not
		-- grow: a HUD that scales up on a big monitor just eats the view of the arena.
		hud.uiScale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.62, 1)
		if hud.onFit then
			hud.onFit(hud.uiScale.Scale)
		end
	end
	if hud.timerUrgent then
		-- A gentle pulse, not a flash: the last ten seconds should raise the pulse without
		-- competing with the fire for attention.
		hud.timer.TextTransparency = 0.25 + 0.25 * math.sin(os.clock() * 6)
	end
end

function Hud.destroy(hud: any)
	hud.bannerToken += 1
	hud.onFit = nil
	hud.gui:Destroy()
end

-- Calls onReady(Remotes) once every arena remote exists, polling rather than waiting so it never
-- holds up the caller. `isCurrent` lets the caller retire it: a view that exits before the remotes
-- arrive returns false, and the poll ends without calling onReady. Returns the polling thread so
-- exit() can also cancel it outright - it is only ever parked in task.wait, never inside require,
-- so cancelling it is safe.
function Hud.awaitRemotes(isCurrent: () -> boolean, onReady: (any) -> ()): thread
	return task.spawn(function()
		while isCurrent() do
			-- The events live in the Folder Arena.Events (Remotes.lua makes it on the server); the
			-- ModuleScript Arena.Remotes is the handle on them.
			local folder = Arena:FindFirstChild("Events")
			local module = Arena:FindFirstChild("Remotes") :: ModuleScript?
			local ready = folder ~= nil and module ~= nil
			if folder then
				for _, name in REMOTE_NAMES do
					if not folder:FindFirstChild(name) then
						ready = false
						break
					end
				end
			end
			if ready and module then
				-- Every event exists, so this require does not yield.
				onReady(require(module) :: any)
				return
			end
			task.wait(0.25)
		end
	end)
end

return Hud
