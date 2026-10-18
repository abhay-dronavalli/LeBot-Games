-- CameraPolish (client) -- the camera faces where you were just put, and the join shot is
-- not the inside of a wall.
--
-- Three problems, one script:
--
-- 1. A SERVER TELEPORT DOES NOT TURN THE CAMERA. Writing HumanoidRootPart.CFrame turns the
--    body; the default camera keeps whatever yaw the player left it at, because that yaw
--    lives in the client's camera module and nothing on the server can reach it. So jumping
--    to a bay spun the character to face the obstacle and left the player looking back down
--    the course at the bay they had just finished. DebugMenu fires `CameraFace` with the
--    direction it pointed the body, and this turns the view to match.
--
-- 2. THE JOIN SHOT. The course entrance sits three studs from the shell's end cap, so a
--    camera that starts pointing the wrong way starts inside a wall. Facing it down the
--    course makes the first frame of the game the view down the hall.
--
-- 3. RESPAWN TAKES THE CAMERA BACK. This is the one that is easy to get wrong: aiming once
--    on CharacterAdded LOOKS right and then silently loses. The engine runs its own
--    "put the camera behind the new character" a few frames later and overwrites us, so the
--    camera ends up facing back up the course again -- measured at lookZ -0.75 after an
--    ordinary death. The aim therefore HOLDS for a short window instead of firing once.
--
-- HOW YOU TURN THE DEFAULT CAMERA. You cannot just assign Camera.CFrame -- the camera module
-- overwrites it on the next RenderStep. The supported move is to take the camera, point it,
-- and hand it back: on the Scriptable -> Custom transition the module re-derives its yaw and
-- pitch from wherever the camera is actually looking, so the new facing sticks.
--
-- IT NEVER FIGHTS THE PLAYER. The hold stops the instant the player moves the mouse (or a
-- gamepad's right stick). Holding a camera against someone who is trying to look around is
-- worse than the bug it fixes.
--
-- IT YIELDS TO THE OVERSEER. OverseerCam holds CameraType = Scriptable for as long as its
-- view is up. If we are not in Custom, someone else is driving and this does nothing --
-- which is what stops a bay change from yanking player 2's top-down shot back to the runner.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CameraFace = Remotes:WaitForChild("CameraFace")

-- How far back the shot sits while we are placing it. The camera module recomputes its own
-- distance from the player's zoom the moment we hand control back, so this only has to be
-- far enough to read as third person for the one frame it exists.
local PLACE_DISTANCE = 14
local PLACE_HEIGHT = 2.5

-- How long the aim is defended after a teleport or a spawn, and how far off it has to drift
-- before we correct it again. The tolerance is what keeps this from thrashing: once the
-- camera is pointing the right way we stop touching it entirely.
local HOLD_AFTER_SPAWN = 1.5
local HOLD_AFTER_TELEPORT = 1.0
local TOLERANCE_DOT = 0.985        -- about 10 degrees

local takenOver = false

-- Any real look input hands the camera back for good.
--
-- "Moved the mouse" is NOT the test. MouseMovement fires for every pixel of ordinary cursor
-- travel, so treating that as intent would hand the camera back before the hold had done
-- anything. The default camera only rotates while the right button is down, or while the
-- mouse is locked to the centre (first person and shift-lock) -- so that is the condition.
local function noteTakeover(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement then
		local rotating = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
		if rotating and input.Delta.Magnitude > 0.5 then
			takenOver = true
		end
	elseif t == Enum.UserInputType.Touch then
		takenOver = true
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		-- a gamepad's look stick reports through Position, not Delta
		if input.Position.Magnitude > 0.2 then
			takenOver = true
		end
	end
end
UserInputService.InputChanged:Connect(noteTakeover)

local function flatten(dir)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	return (flat.Magnitude > 1e-3) and flat.Unit or nil
end

-- Returns: aimed (did we touch it), settled (is it already pointing the right way)
local function aimOnce(flat)
	local cam = Workspace.CurrentCamera
	local ch = player.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	if not cam or not hrp then
		return false, false
	end
	-- Someone else owns the camera (the overseer view). Leave it alone.
	if cam.CameraType ~= Enum.CameraType.Custom then
		return false, false
	end

	local look = flatten(cam.CFrame.LookVector)
	if look and look:Dot(flat) >= TOLERANCE_DOT then
		return false, true          -- already facing the right way; do not touch it
	end

	local focus = hrp.Position + Vector3.new(0, PLACE_HEIGHT, 0)
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.lookAt(focus - flat * PLACE_DISTANCE, focus)
	cam.Focus = CFrame.new(focus)
	cam.CameraType = Enum.CameraType.Custom

	local hum = ch:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
	return true, true
end

-- Hold the aim for `seconds`, correcting whenever something knocks it off, and giving up
-- immediately if the player starts looking around themselves.
local function holdAim(dir, seconds)
	local flat = flatten(dir)
	if not flat then
		return
	end
	takenOver = false
	task.spawn(function()
		local deadline = os.clock() + seconds
		while os.clock() < deadline and not takenOver do
			aimOnce(flat)
			RunService.RenderStepped:Wait()
		end
	end)
end

CameraFace.OnClientEvent:Connect(function(dir)
	if typeof(dir) ~= "Vector3" then
		return
	end
	-- One frame of grace: the teleport and this event land together, and aiming at the
	-- character's OLD position leaves the camera facing the right way from the wrong place.
	task.defer(function()
		RunService.RenderStepped:Wait()
		holdAim(dir, HOLD_AFTER_TELEPORT)
	end)
end)

-- The join / respawn shot, pointed down the course (+Z). Held, because the engine's own
-- respawn camera reset lands a few frames after CharacterAdded and would otherwise win.
player.CharacterAdded:Connect(function()
	holdAim(Vector3.new(0, 0, 1), HOLD_AFTER_SPAWN)
end)
if player.Character then
	holdAim(Vector3.new(0, 0, 1), HOLD_AFTER_SPAWN)
end

----------------------------------------------------------------
-- Low ceilings: pull the camera in before it clips through one.
----------------------------------------------------------------
-- In the dark room the camera was ending up at y = 13.57 with the ceiling slab's underside
-- at 13.5 -- a tenth of a stud INSIDE it. Roblox's Popper pulls the camera closer to avoid
-- an occluder, but in a 14-stud-tall sealed box there is nowhere left to go, so it settles
-- flush against the roof and the near plane pokes out the far side. You then see straight
-- through the ceiling at whatever is above, which since the hall went in is a lit window.
-- In the one bay whose entire premise is that you cannot see, that is fatal.
--
-- Rather than special-case bay 4, measure: look up, and if there is a roof overhead, cap the
-- zoom at a fraction of the clearance so the camera physically cannot reach it. Open bays
-- find nothing above and keep the full range.
local DEFAULT_ZOOM = player.CameraMaxZoomDistance
local CEILING_SEARCH = 26          -- how far up we bother looking
local CLEARANCE_FRACTION = 0.7     -- measured: 0.7 * clearance sits the camera well clear
local MIN_ZOOM = 5

-- A ceiling is something broad enough to actually be over you. Without this the crane's
-- rail beams (1 x 1 x 134, at y = 18) and the roof trusses read as ceilings and squash the
-- camera in the middle of a perfectly open bay.
local function isCeiling(part)
	return part.Size.X > 8 and part.Size.Z > 8
end

local zoomParams = RaycastParams.new()
zoomParams.FilterType = Enum.RaycastFilterType.Exclude

task.spawn(function()
	while true do
		task.wait(0.2)
		local ch = player.Character
		local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
		if hrp then
			zoomParams.FilterDescendantsInstances = {ch}
			local hit = workspace:Raycast(hrp.Position, Vector3.new(0, CEILING_SEARCH, 0), zoomParams)
			local want = DEFAULT_ZOOM
			if hit and isCeiling(hit.Instance) then
				local clearance = hit.Position.Y - hrp.Position.Y
				want = math.clamp(clearance * CLEARANCE_FRACTION, MIN_ZOOM, DEFAULT_ZOOM)
			end
			if math.abs(player.CameraMaxZoomDistance - want) > 0.25 then
				player.CameraMaxZoomDistance = want
			end
		end
	end
end)

print("[CameraPolish] camera follows teleports and respawns; join shot faces down the course")
