--!strict
-- Paste this into a Script in ServerScriptService, with Bridge, Mapping, SkyArm, BlockSync
-- and BoardNotice as ModuleScripts beside it. Enable
-- Game Settings -> Security -> Allow HTTP Requests first, then press Play.
--
-- This is the smallest thing that proves the link: the Sky Arm mirrors the real arm, real
-- blocks become platforms, and pressing a key sends an effect back to the robot. Game modes
-- build on top of it and should not need to touch Bridge.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Bridge = require(script.Parent.Bridge)
local Mapping = require(script.Parent.Mapping)
local SkyArm = require(script.Parent.SkyArm)
local BlockSync = require(script.Parent.BlockSync)
local BoardNotice = require(script.Parent.BoardNotice)

-- localhost works when Studio and the robot process share a laptop. Otherwise use the robot
-- laptop's LAN IP, e.g. "ws://192.168.1.42:8765".
local URL = "ws://localhost:8765"

local arm = SkyArm.new(workspace, { thickness = 3 })
local blocks = BlockSync.new(workspace)

-- Blocks come from a vision model on the robot laptop, which can fail in ways that look like
-- nothing at all from in here - most importantly an OpenAI account with no credits left. This
-- puts that on screen instead of letting the board quietly stop moving.
local notice = BoardNotice.new()

-- A floor under the sheet's build zone, so there is something to stand on while testing.
--
-- Its size comes from the hello frame, never from constants here. The sheet is landscape -
-- 279.4 x 215.9 mm - and this used to hardcode those two numbers the other way round, which
-- built a portrait pad: the floor stopped at 99 studs across where real blocks map out to 128,
-- so a block placed on the right-hand side of the real sheet appeared off the edge of the
-- world. Python already measures the sheet from the tag fit and sends it, so ask rather than
-- assume.
local pad = Instance.new("Part")
pad.Name = "SheetPad"
pad.Anchored = true
pad.Color = Color3.fromRGB(40, 48, 62)
pad.Material = Enum.Material.Concrete
pad.Parent = workspace

local function fitPad(wMm: number, hMm: number)
	local s = Mapping.STUDS_PER_MM
	-- Sheet x -> Roblox X, sheet y -> Roblox Z. Same axis convention as Mapping.point.
	pad.Size = Vector3.new(wMm * s, 1, hMm * s)
	pad.Position = Mapping.ORIGIN + Vector3.new(pad.Size.X / 2, -0.5, pad.Size.Z / 2)
end

fitPad(279.4, 215.9)        -- replaced by the real figures the moment hello arrives

-- Blocks are rendered as true cubes, so a block resting on the table is a 22-stud wall - way
-- past the ~7 studs a default character can clear. The player has to be able to climb onto one
-- to ride it, so the jump is scaled to the block rather than the block flattened to the jump.
local cubeMm = 48

local function fitJumpToBlocks(character)
	local hum = character:FindFirstChildOfClass("Humanoid")
		or character:WaitForChild("Humanoid", 5)
	if not hum then
		return
	end
	hum.UseJumpPower = false        -- JumpHeight is ignored while UseJumpPower is true
	hum.JumpHeight = Mapping.jumpHeight(cubeMm)
end

local function refitEveryone()
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			task.spawn(fitJumpToBlocks, player.Character)
		end
	end
end

Bridge.onHello(function(h)
	blocks:setCube(h.space and h.space.cube_mm)
	if h.board then
		-- Says in the log how often blocks can be expected to change at all, so a board that
		-- sits still for half a minute is not mistaken for a broken link.
		print(("[Main] board read by %s, %s"):format(
			tostring(h.board.reader or "nothing"), tostring(h.board.trigger or "never")))
	end
	if h.space and h.space.sheet then
		fitPad(h.space.sheet.w_mm, h.space.sheet.h_mm)
	end
	cubeMm = (h.space and h.space.cube_mm) or cubeMm
	refitEveryone()                 -- the real cube size only arrives with the hello frame
	print(("[Main] sheet %0.0f x %0.0f mm -> %0.0f x %0.0f studs")
		:format(h.space.sheet.w_mm, h.space.sheet.h_mm,
			h.space.sheet.w_mm * Mapping.STUDS_PER_MM,
			h.space.sheet.h_mm * Mapping.STUDS_PER_MM))
end)

Bridge.onState(function(s)
	arm:update(s.arm)
	blocks:update(s.blocks)
	notice:update(s.notes and s.notes.board)
end)

Bridge.connect(URL)

-- Prove the Roblox -> robot direction. Any of these makes the real arm misbehave on cue.
local DEMO_EVENTS = {
	[Enum.KeyCode.One] = { "earthquake", 0.7, 4 },
	[Enum.KeyCode.Two] = { "fog", 0.6, 5 },
	[Enum.KeyCode.Three] = { "mirror", 1.0, 6 },
	[Enum.KeyCode.Four] = { "freeze", 1.0, 2.5 },
}

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(fitJumpToBlocks)
	if player.Character then
		fitJumpToBlocks(player.Character)
	end
	print(("[Main] %s joined; jump height %.0f studs; press 1-4 on the client to send an effect")
		:format(player.Name, Mapping.jumpHeight(cubeMm)))
end)

-- Wire the keys from a LocalScript through a RemoteEvent in a real build. For a quick test,
-- fire one from the command bar instead:
--     require(game.ServerScriptService.Bridge).sendEvent("earthquake", 0.7, 4)
local heartbeat = 0
RunService.Heartbeat:Connect(function(dt)
	heartbeat += dt
	if heartbeat >= 5 then
		heartbeat = 0
		print(("[Main] link=%s frames=%d applied=%d")
			:format(tostring(Bridge.isConnected()), Bridge.framesReceived, Bridge.framesApplied))
	end
end)

return nil
