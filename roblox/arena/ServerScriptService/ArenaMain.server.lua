--!strict
-- Dragon Arena. Paste into a Script in ServerScriptService, with Bridge and Mapping beside it and
-- the Arena modules in a Folder named `Arena` (see roblox/arena/README.md for the layout).
--
-- One operator drives the real SO-101 with the leader arm. In here that arm is a giant dragon in a
-- volcanic arena, attacking up to twelve players by slamming, sweeping and breathing fire. Players
-- dodge and grab power-ups that fire real effects back at the real arm. Survive the timer and the
-- players win; kill everyone and the dragon does.
--
-- The order of operations matters in two places:
--
--   `hello` before anything is built. The sheet size and the arm base arrive in that frame, and the
--   arena floor is built from them - so Arena:build waits for it rather than guessing a rectangle.
--   Pickups likewise waits for `hello.effects` before it can spawn anything.
--
--   Dragon before effects, every frame. DragonEffects positions its overlays off the segment
--   pivots, so the dragon has to have moved first or every overlay runs one frame behind the body
--   it is wrapped around.
--
-- This script does not interpret the arm itself. Detection lives in AttackDetect, visuals in
-- AttackFx and DragonEffects, and the floor in Arena. What is here is wiring.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bridge = require(script.Parent.Bridge)
local Mapping = require(script.Parent.Mapping)
local Theme = require(ReplicatedStorage.Arena.Theme)
-- Required for its side effect, not its return: requiring Remotes on the server is what creates
-- the RemoteEvent instances. Doing it here, at the top of the one script that starts the mode,
-- means they exist before any player's LocalScript can WaitForChild them. The modules below also
-- require it, so this is belt and braces - but the ordering is load-bearing and worth stating.
require(ReplicatedStorage.Arena.Remotes)

local modules = script.Parent.Arena
local Arena = require(modules.Arena)
local DragonArm = require(modules.DragonArm)
local AttackDetect = require(modules.AttackDetect)
local AttackFx = require(modules.AttackFx)
local DragonEffects = require(modules.DragonEffects)
local Pickups = require(modules.Pickups)
local Rounds = require(modules.Rounds)
local Sound = require(modules.Sound)

-- localhost works when Studio and the robot process share a laptop. Otherwise the robot laptop's
-- LAN IP, e.g. "ws://192.168.1.42:8765".
local URL = "ws://localhost:8765"

-- Who sees the overhead operator camera. Set this to the operator's Roblox username; anyone else
-- plays normally. Left empty, nobody gets it - which is the right default for a public server.
local OPERATOR_NAME = ""

-- Marked with an attribute rather than a RemoteEvent. This is decided the instant the player
-- joins, which is before their LocalScript has connected to anything, and an event fired at a
-- client that is not listening yet is just lost - the operator would get a normal player view and
-- no obvious reason why. An attribute is state the client can read whenever it starts.
local OPERATOR_ATTRIBUTE = "ArenaOperator"

-- Characters are handed out by Rounds, never automatically. Spectating in this mode means having
-- no body at all, and an eliminated player whose character reloaded on a timer would be back in
-- the arena mid-round: uncounted, un-killable, and still solid enough for the dragon to hit.
Players.CharacterAutoLoads = false

local arena = Arena.new(workspace)
local dragon = DragonArm.new(workspace)
local detect = AttackDetect.new()
local fx = AttackFx.new(workspace, arena, dragon)
local effects = DragonEffects.new(dragon)
local pickups = Pickups.new(workspace, arena, Bridge)
local rounds = Rounds.new(arena, dragon, pickups)
local sound = Sound.new(workspace)

-- ---------------------------------------------------------------------------------------------
-- Attacks
-- ---------------------------------------------------------------------------------------------

detect.onSlam = function(tipMm, speed)
	fx:slam(tipMm, speed)
	sound:at("slam", Mapping.point(tipMm), 0.8)
end

detect.onSweepStart = function()
	fx:sweepStart()
	local head = dragon.segments[5]
	if head then
		sound:startLoop("sweep", head.core, 0.5)
	end
end
detect.onSweep = function(tipMm, dir) fx:sweep(tipMm, dir) end
detect.onSweepEnd = function()
	fx:sweepEnd()
	sound:stopLoop("sweep")
end

detect.onFireStart = function(frac)
	fx:fireStart(frac)
	local head = dragon.segments[5]
	if head then
		sound:at("roar", head.core.Position, 0.9)
		sound:startLoop("flame", head.core, 0.6)
	end
end
detect.onFire = function(frac) fx:fire(frac) end
detect.onFireEnd = function()
	fx:fireEnd()
	sound:stopLoop("flame")
end

-- A hit is the dragon's doing, so the round decides what it costs. AttackFx only reports it.
fx.onHit = function(player, kind)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		sound:at("eliminated", root.Position, 0.6)
	end
	rounds:eliminate(player, kind)
end

-- A player landed a debuff on the real arm. The toast says who and what; it is deliberately the
-- effect's own cool colour, never a warm one, because this is the players' win.
pickups.onLanded = function(player, name)
	rounds:banner("DRAGON " .. Theme.effectLabel(name) .. "!", Theme.effectColor(name), 1.5, player.Name)
	sound:ui("debuff", 0.5)
end

-- ---------------------------------------------------------------------------------------------
-- The link
-- ---------------------------------------------------------------------------------------------

Bridge.onHello(function(h)
	cubeMm = (h.space and h.space.cube_mm) or cubeMm
	arena:build(h.space)
	pickups:setEffects(h.effects)
	sound:ambience()
	print(("[Arena] source=%s, floor from sheet %0.0f x %0.0f mm, arm base (%0.1f, %0.1f)")
		:format(tostring(h.source),
			h.space and h.space.sheet and h.space.sheet.w_mm or 0,
			h.space and h.space.sheet and h.space.sheet.h_mm or 0,
			h.space and h.space.arm_base_mm and h.space.arm_base_mm[1] or 0,
			h.space and h.space.arm_base_mm and h.space.arm_base_mm[2] or 0))
	rounds:start()
end)

Bridge.onState(function(s)
	-- Dragon first: everything below reads where its parts ended up.
	dragon:update(s.arm, s.arm_age)
	effects:update(s.effects)
	rounds:setEffects(s.effects)

	-- Always called, including on a stale frame. A stale arm is a harmless dragon (hard rule 5),
	-- and AttackDetect is what enforces that - it needs the frame to notice the staleness and shut
	-- down whatever was running. Skipping the call would leave a live fire cone burning on a dead
	-- link, still killing players with nobody driving it.
	detect:update(s)
end)

Bridge.connect(URL)

-- ---------------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------------

-- The real cube size arrives with `hello`; 48 is only what it is until then. Blocks render as true
-- cubes at the shipped scale, so a resting block is a ~22-stud wall - far past the ~7 studs a
-- default character clears. The jump is scaled to the block rather than the block flattened to the
-- jump, exactly as the obby's Main does, and Arena's platform heights follow the same number.
local cubeMm = 48

local function onCharacter(player: Player, char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
	if hum and hum:IsA("Humanoid") then
		hum.UseJumpPower = false        -- JumpHeight is ignored while UseJumpPower is true
		hum.JumpHeight = Mapping.jumpHeight(cubeMm)
	end
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char) onCharacter(player, char) end)

	-- The operator is excluded *before* playerAdded, which is what hands out characters: the
	-- overhead view is scriptable and a body on the floor would be one more thing to dodge.
	if OPERATOR_NAME ~= "" and player.Name == OPERATOR_NAME then
		rounds:exclude(player)
		player:SetAttribute(OPERATOR_ATTRIBUTE, true)
		return
	end

	rounds:playerAdded(player)
	if rounds.state == "Waiting" then
		rounds:start()
	end
end)

Players.PlayerRemoving:Connect(function(player)
	rounds:playerRemoving(player)
end)

RunService.Heartbeat:Connect(function(dt)
	pickups:step(dt)
	rounds:step(dt)
end)

local report = 0
RunService.Heartbeat:Connect(function(dt)
	report += dt
	if report >= 5 then
		report = 0
		print(("[Arena] link=%s state=%s dormant=%s frames=%d applied=%d")
			:format(tostring(Bridge.isConnected()), rounds.state,
				tostring(dragon:isDormant()), Bridge.framesReceived, Bridge.framesApplied))
	end
end)

return nil
