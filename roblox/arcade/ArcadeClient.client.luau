-- Studio location: StarterPlayer.StarterPlayerScripts.ArcadeClient (LocalScript)
-- Arcade client: cabinet screens (per player, so LOCKED shows your own wins), banners,
-- the DON'T PRESS shake, and the Sky Arm claw pose.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local arcadeState = ReplicatedStorage:WaitForChild("Arcade")
local fxRemote = arcadeState:WaitForChild("ArcadeFx")
local armState = arcadeState:WaitForChild("Arm")
local workshop = workspace:WaitForChild("Workshop")
local cabinets = workshop:WaitForChild("Bays")
local skyArm = workshop:WaitForChild("WallArm")

local GREEN = Color3.fromRGB(90, 255, 140)
local YELLOW = Color3.fromRGB(255, 210, 60)
local ORANGE = Color3.fromRGB(255, 150, 60)
local RED = Color3.fromRGB(255, 80, 80)
local GRAY = Color3.fromRGB(140, 140, 160)

------------------------------------------------------------------ HUD

local gui = Instance.new("ScreenGui")
gui.Name = "ArcadeHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local function label(props)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.GothamBlack
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.4
	t.TextScaled = true
	for k, v in props do
		t[k] = v
	end
	t.Parent = gui
	return t
end

local joinTitle = label({
	Name = "JoinTitle",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 52),
	Size = UDim2.new(0.6, 0, 0, 44),
	Visible = false,
})
local joinSub = label({
	Name = "JoinSub",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 98),
	Size = UDim2.new(0.6, 0, 0, 24),
	Font = Enum.Font.GothamBold,
	Visible = false,
})
local banner = label({
	Name = "Banner",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.4),
	Size = UDim2.fromScale(0.7, 0.13),
	TextTransparency = 1,
	TextStrokeTransparency = 1,
})

local bannerToken = 0
local function showBanner(text, color, duration)
	bannerToken += 1
	local token = bannerToken
	banner.Text = text
	banner.TextColor3 = color
	banner.TextTransparency = 0
	banner.TextStrokeTransparency = 0.3
	task.delay(duration, function()
		if token == bannerToken then
			TweenService:Create(banner, TweenInfo.new(0.5), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		end
	end)
end

local shakeUntil = 0

fxRemote.OnClientEvent:Connect(function(kind, arg)
	if kind == "result" then
		if arg then
			showBanner("+1 WIN!", YELLOW, 3)
		else
			showBanner("NO WIN THIS TIME", GRAY, 2.5)
		end
	elseif kind == "locked" then
		showBanner(string.format("WIN %d MORE GAME%s TO UNLOCK", arg, if arg == 1 then "" else "S"), RED, 2)
	elseif kind == "quake" then
		showBanner(arg .. " PRESSED THE BUTTON!", RED, 2.5)
		shakeUntil = os.clock() + 3
	end
end)

------------------------------------------------------------------ cabinet screens

local function myWins()
	local stats = player:FindFirstChild("leaderstats")
	local wins = stats and stats:FindFirstChild("Wins")
	return if wins then wins.Value else 0
end

local function updateScreen(cab)
	local screen = cab:FindFirstChild("Screen")
	local sg = screen and screen:FindFirstChild("SurfaceGui")
	local portal = cab:FindFirstChild("Portal")
	if not sg or not portal then
		return
	end
	local status, sub = sg.Status, sg.Sub
	local need = (cab:GetAttribute("WinsToUnlock") or 0) - myWins()
	local state = cab:GetAttribute("Status") or "READY"
	local text, color, subText = "READY", GREEN, ""

	if not cab:GetAttribute("Available") then
		text, color = "COMING SOON", GRAY
		if need > 0 then
			subText = string.format("UNLOCKS AT %d WINS", cab:GetAttribute("WinsToUnlock"))
		end
	elseif state == "STARTING" then
		text, color = "STARTING " .. tostring(cab:GetAttribute("Countdown") or ""), YELLOW
		subText = if player:GetAttribute("JoinedMode") == cab.Name then "YOU'RE IN!" else "WALK IN TO JOIN"
	elseif state == "PLAYING" then
		text, color = "PLAYING", GREEN
	elseif state == "ARM IN USE" then
		text, color, subText = "ARM IN USE", ORANGE, "ONE GAME AT A TIME"
	elseif need > 0 then
		text, color = "LOCKED", RED
		subText = string.format("WIN %d MORE GAME%s", need, if need == 1 then "" else "S")
	elseif not arcadeState:GetAttribute("ArmOnline") then
		subText = "ARM OFFLINE \u{00B7} MOCK MODE"
	end

	status.Text = text
	status.TextColor3 = color
	sub.Text = subText

	-- portals pulse while their game is filling up, and dim when they can't be used
	local usable = state == "STARTING" or text == "READY"
	portal.Color = if usable then cab:GetAttribute("Color") or portal.Color else Color3.fromRGB(55, 55, 70)
	if state == "STARTING" then
		portal.Transparency = 0.1 + (math.sin(os.clock() * 6) + 1) * 0.15
	else
		portal.Transparency = if usable then 0.15 else 0.6
	end
end

------------------------------------------------------------------ Sky Arm claw

-- Real joint angle (degrees) -> rig angle: rig = (real + offset) * sign.
-- Tune by moving one real joint at a time and watching the claw.
local CAL = {
	shoulder_pan = { sign = 1, offset = 0 },
	shoulder_lift = { sign = 1, offset = 0 },
	elbow_flex = { sign = 1, offset = 0 },
	wrist_flex = { sign = 1, offset = 0 },
	wrist_roll = { sign = 1, offset = 0 },
}
local JOINTS = { "shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll" }

-- Every arm rig is posed from the same joint data: the lobby's WallArm plus any model tagged
-- "ArmRig" (e.g. the arm in a Flood theme). Each rig carries its own link lengths and idle
-- motion as attributes (defaults = the old ceiling claw); its Mount part sets where it points.
local rigs = {}

local function addRig(model)
	if rigs[model] then
		return
	end
	local mount = model:WaitForChild("Mount", 10)
	if not mount or not model.Parent or rigs[model] then
		return
	end
	local function rigAttr(name, default)
		local v = model:GetAttribute(name)
		return if type(v) == "number" then v else default
	end
	local rig = {
		parts = {},
		-- flip the mount so the arm's local +Y points out of the mount's -Y face
		mountCF = mount.CFrame * CFrame.new(0, -1, 0) * CFrame.Angles(math.pi, 0, 0),
		current = { shoulder_pan = 0, shoulder_lift = 0, elbow_flex = 0, wrist_flex = 0, wrist_roll = 0, gripper = 50 },
		DIM = {
			turret = rigAttr("Len_turret", 2),
			shoulder = rigAttr("Len_shoulder", 4.5),
			upper = rigAttr("Len_upper", 12),
			fore = rigAttr("Len_fore", 13),
			hand = rigAttr("Len_hand", 2),
			finger = rigAttr("Len_finger", 5.5),
			gripMin = rigAttr("Len_gripMin", 0.6),
			gripRange = rigAttr("Len_gripRange", 1.6),
		},
		IDLE = {
			panAmp = rigAttr("Idle_panAmp", 70),
			liftBase = rigAttr("Idle_liftBase", 35),
			liftAmp = rigAttr("Idle_liftAmp", 20),
			elbowBase = rigAttr("Idle_elbowBase", 45),
			elbowAmp = rigAttr("Idle_elbowAmp", 25),
			wristBase = rigAttr("Idle_wristBase", 25),
			wristAmp = rigAttr("Idle_wristAmp", 20),
			rollAmp = rigAttr("Idle_rollAmp", 60),
		},
	}
	for _, p in model:GetChildren() do
		rig.parts[p.Name] = p
	end
	rigs[model] = rig
end

addRig(skyArm)
for _, model in CollectionService:GetTagged("ArmRig") do
	task.spawn(addRig, model)
end
CollectionService:GetInstanceAddedSignal("ArmRig"):Connect(function(model)
	task.spawn(addRig, model)
end)
CollectionService:GetInstanceRemovedSignal("ArmRig"):Connect(function(model)
	rigs[model] = nil
end)

local function idlePose(t, IDLE)
	return {
		shoulder_pan = math.sin(t * 0.35) * IDLE.panAmp,
		shoulder_lift = IDLE.liftBase + math.sin(t * 0.6) * IDLE.liftAmp,
		elbow_flex = IDLE.elbowBase + math.sin(t * 0.8 + 1) * IDLE.elbowAmp,
		wrist_flex = IDLE.wristBase + math.sin(t * 1.1) * IDLE.wristAmp,
		wrist_roll = math.sin(t * 0.5) * IDLE.rollAmp,
		gripper = (math.sin(t * 0.9) + 1) * 50,
	}
end

local function livePose()
	local pose = {}
	for _, j in JOINTS do
		local c = CAL[j]
		pose[j] = ((armState:GetAttribute(j) or 0) + c.offset) * c.sign
	end
	pose.gripper = armState:GetAttribute("gripper") or 50
	return pose
end

local function setPart(parts, name, cf)
	local p = parts[name]
	if p then
		p.CFrame = cf
	end
	local glow = parts[name .. "Glow"]
	if glow then
		glow.CFrame = cf
	end
end

local function poseArm(rig, dt)
	local current, DIM, parts = rig.current, rig.DIM, rig.parts
	-- no live robot: ease into the rest pose (the idle pose at t = 0) and hold still
	local target = if arcadeState:GetAttribute("ArmLive") then livePose() else idlePose(0, rig.IDLE)
	local k = math.min(1, dt * 10)
	for j, v in target do
		current[j] += (v - current[j]) * k
	end
	local r = math.rad
	local base = rig.mountCF * CFrame.Angles(0, r(current.shoulder_pan), 0)
	setPart(parts, "Turret", base * CFrame.new(0, DIM.turret, 0) * CFrame.Angles(0, 0, r(90)))
	local shoulder = base * CFrame.new(0, DIM.shoulder, 0)
	setPart(parts, "Shoulder", shoulder)
	local upper = shoulder * CFrame.Angles(r(current.shoulder_lift), 0, 0)
	setPart(parts, "UpperArm", upper * CFrame.new(0, DIM.upper / 2, 0))
	local elbow = upper * CFrame.new(0, DIM.upper, 0)
	setPart(parts, "Elbow", elbow)
	local fore = elbow * CFrame.Angles(r(current.elbow_flex), 0, 0)
	setPart(parts, "Forearm", fore * CFrame.new(0, DIM.fore / 2, 0))
	local wrist = fore * CFrame.new(0, DIM.fore, 0)
	setPart(parts, "WristJoint", wrist)
	local hand = wrist * CFrame.Angles(r(current.wrist_flex), 0, 0) * CFrame.Angles(0, r(current.wrist_roll), 0)
	setPart(parts, "Hand", hand * CFrame.new(0, DIM.hand, 0))
	local open = DIM.gripMin + math.clamp(current.gripper, 0, 100) / 100 * DIM.gripRange
	setPart(parts, "FingerL", hand * CFrame.new(-open, DIM.finger, 0))
	setPart(parts, "FingerR", hand * CFrame.new(open, DIM.finger, 0))
end

------------------------------------------------------------------ per frame

-- Heartbeat rather than RenderStepped so everything keeps updating while Studio is unfocused.
RunService.Heartbeat:Connect(function(dt)
	for _, cab in cabinets:GetChildren() do
		updateScreen(cab)
	end
	for model, rig in rigs do
		if model.Parent then
			poseArm(rig, dt)
		else
			rigs[model] = nil
		end
	end

	-- join window banner for everyone still in the arcade
	local joinMode = arcadeState:GetAttribute("JoinMode") or ""
	if joinMode ~= "" then
		local t = arcadeState:GetAttribute("JoinCountdown") or 0
		local name = string.upper(arcadeState:GetAttribute("JoinTitle") or joinMode)
		joinTitle.Visible, joinSub.Visible = true, true
		if player:GetAttribute("JoinedMode") == joinMode then
			joinTitle.Text = "YOU'RE IN!"
			joinSub.Text = string.format("%s starts in %d", name, t)
		else
			joinTitle.Text = string.format("%s STARTING IN %d", name, t)
			joinSub.Text = "Walk into its portal to join"
		end
	else
		joinTitle.Visible, joinSub.Visible = false, false
	end

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and os.clock() < shakeUntil then
		hum.CameraOffset = Vector3.new((math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2, (math.random() - 0.5) * 1.2)
	elseif hum and shakeUntil > 0 then
		hum.CameraOffset = Vector3.zero
		shakeUntil = 0
	end
end)
