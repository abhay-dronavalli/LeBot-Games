-- ReplicatedStorage.ArmTwin.Stick
-- The arm twin as a stick figure drawn from the bridge's arm.points (PROTOCOL.md: world points in sheet mm,
-- base to tip, already through the real arm's kinematics and calibration). One link part spans each pair
-- of consecutive points, a joint ball sits on every point and a base column runs from the paper up to the
-- first point. No link lengths, joint signs or offsets are involved, so the tip lands over the cell the
-- real jaw is over.
--   Stick.payload(points, board)  server: sheet-mm points -> { foot, points, scale } in world studs over
--                                 the board (Grid.sheetToWorld, the LiveBoard's scale), for the ArmPose remote
--   Stick.restPayload(twinModel)  the folded rest pose (Config.twinRestPose through ArmTwin.Rig) standing
--                                 at the hidden rig's pivot, in the same form
--   Stick.attach(twinModel, remote, parent)  client: draws the stick in a Model "ArmStick" under parent,
--                                 easing toward each sample every Heartbeat; shows the rest pose until the
--                                 first sample, for an empty one, and once samples stop for STALE_SECONDS.
--                                 Hides the parts-built rig (twinModel) on this client, so only one arm
--                                 is ever drawn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.PatternMatch.Config)
local Grid = require(ReplicatedStorage.PatternMatch.Grid)
local Rig = require(script.Parent.Rig)
local Driver = require(script.Parent.Driver)

local WHITE = Color3.fromHex("e9e6df") -- links and base: the twin's off-white arm parts
local DARK = Color3.fromHex("2a2d33")  -- joints and tip

local SMOOTHING = 14      -- per second; higher follows samples more tightly
local REST_SMOOTHING = 3  -- per second; slower settle into the rest pose when the data goes away
local STALE_SECONDS = 1   -- no sample for this long -> ease back to the rest pose

local Stick = {}
Stick.STALE_SECONDS = STALE_SECONDS

function Stick.payload(points, board)
	if type(points) ~= "table" or #points == 0 then
		return nil
	end
	local world = {}
	for i, p in ipairs(points) do
		world[i] = Grid.sheetToWorld(p.x, p.y, p.z, board)
	end
	return { foot = Grid.sheetToWorld(points[1].x, points[1].y, 0, board), points = world, scale = Grid.studsPerMm() }
end

function Stick.restPayload(twinModel)
	local pivot = twinModel:GetPivot()
	local world = {}
	for i, p in ipairs(Rig.chainPoints(Driver.rigAngles(Driver.restPose()))) do
		world[i] = pivot:PointToWorldSpace(p)
	end
	return { foot = pivot.Position, points = world, scale = Rig.studsPerCm() / 10 }
end

local function newPart(parent, name, color, shape)
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = true
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- A cylinder spanning a -> b (a Cylinder part's length runs along its local X).
local function span(part, a, b, thickness)
	local length = (b - a).Magnitude
	if length < 0.01 then
		part.Transparency = 1
		return
	end
	part.Transparency = 0
	part.Size = Vector3.new(length, thickness, thickness)
	part.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0)
end

-- Draws one pose ({ foot, points, scale }) on the stick's parts, making any that don't exist yet.
local function draw(model, parts, pose)
	local mm = Config.twinStickMm
	local s = pose.scale
	local pts = pose.points
	if not parts.base then
		parts.base = newPart(model, "Base", WHITE, Enum.PartType.Cylinder)
	end
	span(parts.base, pose.foot, pts[1], mm.base * s)
	for i = 1, #pts - 1 do
		parts.links[i] = parts.links[i] or newPart(model, "Link" .. i, WHITE, Enum.PartType.Cylinder)
		span(parts.links[i], pts[i], pts[i + 1], mm.link * s)
	end
	for i = #pts, #parts.links do
		parts.links[i].Transparency = 1
	end
	for i, p in ipairs(pts) do
		local last = i == #pts
		local ball = parts.joints[i]
		if not ball then
			ball = newPart(model, last and "Tip" or ("Joint" .. i), DARK, Enum.PartType.Ball)
			parts.joints[i] = ball
		end
		local d = (last and mm.tip or mm.joint) * s
		ball.Size = Vector3.new(d, d, d)
		ball.CFrame = CFrame.new(p)
		ball.Transparency = 0
	end
	for i = #pts + 1, #parts.joints do
		parts.joints[i].Transparency = 1
	end
end

-- A copy of a pose, for easing in place.
local function copy(pose)
	return { foot = pose.foot, points = table.clone(pose.points), scale = pose.scale }
end

-- True when a sample is a pose we can draw.
local function isPose(sample)
	return type(sample) == "table" and type(sample.points) == "table" and #sample.points > 0
		and typeof(sample.foot) == "Vector3" and type(sample.scale) == "number"
end
Stick.isPose = isPose

-- Client side. Returns a handle: destroy(), current() (the eased pose), resting() (true while it shows or
-- eases toward the rest pose: no sample yet, an empty one, or stale data) and model.
function Stick.attach(twinModel, remote, parent)
	for _, d in ipairs(twinModel:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Transparency = 1 -- local only: the joint-angle rig stays in the place, unseen
		end
	end
	local model = Instance.new("Model")
	model.Name = "ArmStick"
	model.Parent = parent
	local parts = { links = {}, joints = {} }
	local rest = Stick.restPayload(twinModel)
	local current = copy(rest)
	local target = rest
	local lastSample = nil -- os.clock() of the last drawable sample; nil while resting
	draw(model, parts, current)

	local connections = {}
	table.insert(connections, remote.OnClientEvent:Connect(function(sample)
		if isPose(sample) then
			target = sample
			lastSample = os.clock()
		else
			target = rest
			lastSample = nil
		end
	end))
	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		if lastSample and os.clock() - lastSample > STALE_SECONDS then
			target = rest
			lastSample = nil
		end
		if #target.points ~= #current.points then
			current = copy(target) -- a different chain: no sensible way to ease, so jump
		else
			local k = 1 - math.exp(-(lastSample and SMOOTHING or REST_SMOOTHING) * dt)
			for i, p in ipairs(target.points) do
				current.points[i] = current.points[i]:Lerp(p, k)
			end
			current.foot = current.foot:Lerp(target.foot, k)
			current.scale += (target.scale - current.scale) * k
		end
		draw(model, parts, current)
	end))
	return {
		model = model,
		destroy = function()
			for _, c in ipairs(connections) do
				c:Disconnect()
			end
			model:Destroy()
		end,
		current = function()
			return current
		end,
		resting = function()
			return lastSample == nil
		end,
	}
end

return Stick
