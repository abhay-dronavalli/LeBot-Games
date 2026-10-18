--!strict
-- ReplicatedStorage.Arena.Views.PlayerView
-- Dragon Arena for the player role and for spectators, while the arena is the active game
-- (Core.GameRegistry; the arcade mode sets it from Start to Stop).
--
-- "Active" is a whole-server fact, but the round is not: players who stayed in the lobby, or who
-- went back through the LobbyTeleporter, get this view too. So the HUD is built on enter and kept
-- hidden unless this client is actually in the round - the latest Hud payload says inGame AND the
-- server's "ArenaInGame" attribute is still set on us (the payload stops arriving when we leave, so
-- its last word cannot be trusted on its own). A lobby player sees nothing, no key does anything,
-- no camera shake lands, and the look (Client.Look) stays off unless their camera is at the arena.
--
-- Spectators (ctx.readOnly) mirror the player: they get the payload the server sends spectators
-- (inGame = false, no slots), and the HUD shows while the player-role holder is in the round. It is
-- read only - SlotFire is never sent from a spectator, whatever they press - and with no slots in
-- their payload the ability bar stays hidden rather than showing four "ready" slots that are not.
--
-- What the HUD shows is Client.Hud (survivors pill, timer, chips, banners, spectate line) plus the
-- ability bar, bottom right, with 1-4 on the keyboard and the tiles for touch. Slots fire only
-- while in the round and alive; the server re-checks (it ignores anyone not alive in the round).
--
-- NO PLAYER-PUNISHING EFFECTS. The debuffs belong to the players, so they never flip this screen,
-- fog it, or shake it. The one thing that does shake the camera is a slam, which is the dragon's
-- doing (style guide section 8).
--
-- The aerial view, the V key and SetOperator are gone from this side: the dragon is the robot role
-- now, and its screen is Views.RobotView.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Arena = ReplicatedStorage:WaitForChild("Arena")
local Theme = require(Arena:WaitForChild("Theme"))
local ArenaConfig = require(Arena:WaitForChild("ArenaConfig"))
local Icons = require(Arena:WaitForChild("Icons"))
local Client = Arena:WaitForChild("Client")
local Hud = require(Client:WaitForChild("Hud"))
local Look = require(Client:WaitForChild("Look"))
local Roles = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Roles")) :: any

local C = Theme.Color
local player = Players.LocalPlayer

local IN_GAME = "ArenaInGame"
local ALIVE = "ArenaAlive"
local RENDER_NAME = "ArenaPlayerView"

-- 64 px at full scale. The onFit hook below keeps the rendered size at or above SLOT_MIN_PX by
-- compensating for the HUD's UIScale, because the style guide's floor is a *touch target*, and a
-- target that shrinks with the rest of the HUD stops being one.
local SLOT_PX = 64
local SLOT_MIN_PX = 56

local PlayerView = {}

-- One view session. Everything enter() makes is reachable from here, so exit() can take it apart.
local session = 0
local readOnly = false
local hud: any = nil
local bar: Frame? = nil
local slotTiles: { any } = {}
local latest: any = nil
local remotes: any = nil
local look: any = nil
local connections: { RBXScriptConnection } = {}
local wiring: thread? = nil
local bound = false

local shakeUntil = 0
local shakeStrength = 0

-- The player-role holder, whose round a spectator is watching.
local function rolePlayer(): Player?
	for _, p in Players:GetPlayers() do
		if Roles.of(p) == Roles.PLAYER then
			return p
		end
	end
	return nil
end

-- Whether the HUD is shown at all.
local function inRound(): boolean
	if not latest then
		return false
	end
	if readOnly then
		local watched = rolePlayer()
		-- No player-role holder to check against: trust that the server is still sending.
		return watched == nil or watched:GetAttribute(IN_GAME) == true
	end
	return latest.inGame == true and player:GetAttribute(IN_GAME) == true
end

-- Whether a slot key or tap does anything.
local function canFire(): boolean
	return not readOnly
		and remotes ~= nil
		and inRound()
		and latest.alive == true
		and player:GetAttribute(ALIVE) == true
end

local function fire(i: number)
	if canFire() then
		remotes.SlotFire:FireServer(i)
	end
end

-- ---------------------------------------------------------------------------------------------
-- The ability bar
-- ---------------------------------------------------------------------------------------------

local function buildBar(gui: ScreenGui)
	local frame = Instance.new("Frame")
	frame.Name = "Abilities"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -16, 1, -16)
	frame.Size = UDim2.new(0, (SLOT_PX + 8) * ArenaConfig.ABILITY_SLOTS, 0, SLOT_PX)
	frame.Visible = false
	frame.Parent = gui
	bar = frame

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	for i = 1, ArenaConfig.ABILITY_SLOTS do
		local tile = Hud.panel(frame)
		tile.Size = UDim2.new(0, SLOT_PX, 0, SLOT_PX)
		tile.LayoutOrder = i

		local border = Instance.new("UIStroke")
		border.Color = C.UiText
		border.Thickness = 2
		border.Parent = tile

		local label = Hud.text(tile, Theme.Font.Label, 11, C.UiText)
		label.Position = UDim2.new(0, 2, 1, -16)
		label.Size = UDim2.new(1, -4, 0, 14)
		label.Text = ""
		label.ZIndex = 3

		local key = Hud.text(tile, Theme.Font.Label, 12, C.UiText)
		key.Position = UDim2.new(0, 4, 0, 2)
		key.Size = UDim2.new(0, 14, 0, 14)
		key.Text = tostring(i)
		key.TextTransparency = 0.4

		-- Cooldown is a bottom-up fill, so a slot visibly comes back rather than just reappearing.
		local cd = Instance.new("Frame")
		cd.BackgroundColor3 = C.UiInk
		cd.BackgroundTransparency = 0.5
		cd.BorderSizePixel = 0
		cd.AnchorPoint = Vector2.new(0, 1)
		cd.Position = UDim2.new(0, 0, 1, 0)
		cd.Size = UDim2.new(1, 0, 0, 0)
		cd.Parent = tile

		local button = Instance.new("TextButton")
		button.BackgroundTransparency = 1
		button.Text = ""
		button.Size = UDim2.new(1, 0, 1, 0)
		button.Parent = tile
		-- Destroyed with the gui, which takes this connection with it.
		button.Activated:Connect(function()
			fire(i)
		end)

		slotTiles[i] = { tile = tile, border = border, label = label, cd = cd, icon = nil, held = nil }
	end

	hud.onFit = function(scale: number)
		local px = math.max(SLOT_PX, SLOT_MIN_PX / math.max(scale, 0.01))
		for _, t in slotTiles do
			t.tile.Size = UDim2.new(0, px, 0, px)
		end
		frame.Size = UDim2.new(0, (px + 8) * ArenaConfig.ABILITY_SLOTS, 0, px)
	end
end

local function drawSlots(slots: { any })
	for i, tile in slotTiles do
		local s = slots and slots[i]

		-- Only redraw when the contents actually change. drawSlots runs on every payload, and a
		-- slot that rebuilds its frames eight times a second visibly flickers.
		local want = s and s.name or nil
		if want ~= tile.held then
			tile.held = want
			if tile.icon then
				tile.icon:Destroy()
				tile.icon = nil
			end
			if want then
				tile.icon = Icons.draw(tile.tile, want, s.color)
			end
		end

		if s and s.name then
			-- A slot holding a picked-up debuff carries that effect's colour.
			tile.border.Color = s.color
			tile.border.Thickness = 3
			tile.label.Text = s.label
			tile.label.TextColor3 = s.color
			tile.cd.Size = UDim2.new(1, 0, 0, 0)
		elseif s and s.cooldown then
			tile.border.Color = C.UiText
			tile.border.Thickness = 2
			tile.label.Text = ""
			local f = math.clamp(s.cooldown / ArenaConfig.ABILITY_COOLDOWN_S, 0, 1)
			tile.cd.Size = UDim2.new(1, 0, f, 0)
		else
			-- An empty, ready slot glows Power: cool, because it belongs to the player.
			tile.border.Color = C.Power
			tile.border.Thickness = 3
			tile.label.Text = ""
			tile.cd.Size = UDim2.new(1, 0, 0, 0)
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Per frame: visibility, the timer pulse, and the slam shake
-- ---------------------------------------------------------------------------------------------

local function render()
	if not hud then
		return
	end
	-- Read every frame rather than on change: it is a few attribute reads, and it catches every
	-- way out of the round (died and left, teleported to the lobby, the game stopped) without a
	-- signal for each.
	local shown = inRound()
	if hud.gui.Enabled ~= shown then
		hud.gui.Enabled = shown
	end
	if bar then
		local wantBar = shown and latest ~= nil and latest.slots ~= nil
		if bar.Visible ~= wantBar then
			bar.Visible = wantBar
		end
	end
	Hud.step(hud)

	if os.clock() >= shakeUntil then
		shakeStrength = 0
		return
	end
	if readOnly or not shown then
		return
	end
	-- Offsets the camera's CFrame only, after the default camera has placed it this frame (the
	-- binding sits just above Camera priority). The default third-person camera stays in charge
	-- (style guide section 10), so nothing fights the player's own control.
	local camera = workspace.CurrentCamera
	local f = shakeUntil - os.clock()
	local amp = shakeStrength * math.min(f, 0.4) * 6
	camera.CFrame = camera.CFrame * CFrame.new(
		(math.random() - 0.5) * amp,
		(math.random() - 0.5) * amp,
		0)
end

-- ---------------------------------------------------------------------------------------------
-- enter / exit
-- ---------------------------------------------------------------------------------------------

local function wire(r: any)
	remotes = r
	table.insert(connections, r.Hud.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then
			return
		end
		latest = payload
		-- Drawn even while hidden would be wasted work; the next payload after we join the round
		-- fills everything in within an eighth of a second.
		if not inRound() then
			return
		end
		Hud.apply(hud, payload)
		if payload.slots then
			drawSlots(payload.slots)
		end
	end))
	table.insert(connections, r.Banner.OnClientEvent:Connect(function(info)
		if typeof(info) == "table" and inRound() then
			Hud.banner(hud, info)
		end
	end))
	-- A slam, and only a slam. The server sends it only to alive players near the impact.
	table.insert(connections, r.Shake.OnClientEvent:Connect(function(strength, seconds)
		if readOnly or not inRound() then
			return
		end
		shakeStrength = math.max(shakeStrength, tonumber(strength) or 0)
		shakeUntil = math.max(shakeUntil, os.clock() + (tonumber(seconds) or 0))
	end))
end

function PlayerView.enter(ctx: any)
	PlayerView.exit()
	session += 1
	local mine = session
	readOnly = ctx ~= nil and ctx.readOnly == true

	hud = Hud.new("ArenaHud")
	buildBar(hud.gui)
	look = Look.start(false)

	-- Number keys fire the slots too; the tiles are for touch. Gated in fire(): outside the round,
	-- dead, or spectating, a key press does nothing at all.
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local n = input.KeyCode.Value - Enum.KeyCode.One.Value + 1
		if n >= 1 and n <= ArenaConfig.ABILITY_SLOTS then
			fire(n)
		end
	end))

	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, render)
	bound = true

	wiring = Hud.awaitRemotes(function()
		return session == mine
	end, function(r)
		wiring = nil
		if session == mine then
			wire(r)
		end
	end)
end

-- Safe to call twice, and before any enter.
function PlayerView.exit()
	session += 1
	if wiring then
		if coroutine.status(wiring) == "suspended" then
			task.cancel(wiring)
		end
		wiring = nil
	end
	for _, c in connections do
		c:Disconnect()
	end
	table.clear(connections)
	if bound then
		RunService:UnbindFromRenderStep(RENDER_NAME)
		bound = false
	end
	Look.stop(look)
	look = nil
	if hud then
		Hud.destroy(hud)
		hud = nil
	end
	bar = nil
	table.clear(slotTiles)
	latest = nil
	remotes = nil
	readOnly = false
	shakeUntil = 0
	shakeStrength = 0
end

return PlayerView
