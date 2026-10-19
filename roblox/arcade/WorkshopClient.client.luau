-- Studio location: StarterPlayer.StarterPlayerScripts.WorkshopClient (LocalScript)
-- Workshop lobby visuals only: bay status lights, beacons and tunnel lights, the wall arm's
-- shoulder LED, and keeping the portal triggers invisible. It reads the same attributes
-- ArcadeManager sets on each bay; there is no game logic here.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local arcadeState = ReplicatedStorage:WaitForChild("Arcade")
local workshop = workspace:WaitForChild("Workshop")
local bays = workshop:WaitForChild("Bays")
local arm = workshop:WaitForChild("WallArm")

local GREEN = Color3.fromRGB(63, 185, 80)
local AMBER = Color3.fromRGB(255, 176, 32)
local RED = Color3.fromRGB(217, 63, 63)
local GREY = Color3.fromRGB(95, 98, 104)
local LED_OFF = Color3.fromRGB(40, 60, 40)

local function myWins()
	local stats = player:FindFirstChild("leaderstats")
	local wins = stats and stats:FindFirstChild("Wins")
	return if wins then wins.Value else 0
end

local function stateOf(bay)
	if not bay:GetAttribute("Available") then
		return "COMING SOON"
	end
	local status = bay:GetAttribute("Status") or "READY"
	if status ~= "READY" then
		return status -- STARTING, PLAYING or ARM IN USE
	end
	if (bay:GetAttribute("WinsToUnlock") or 0) > myWins() then
		return "LOCKED"
	end
	return "READY"
end

-- remember where each beacon sits so it can spin in place
local beaconHome = {}

local function updateBay(bay, t)
	local portal = bay:FindFirstChild("Portal")
	if portal then
		portal.LocalTransparencyModifier = 1 -- the trigger stays invisible
	end
	local light = bay:FindFirstChild("StatusLight")
	local beacon = bay:FindFirstChild("Beacon")
	if not light or not beacon then
		return
	end

	local state = stateOf(bay)
	local color, lit, spin = GREY, false, false
	if state == "READY" then
		color, lit = GREEN, true
	elseif state == "LOCKED" then
		color, lit, spin = RED, true, true
	elseif state == "STARTING" then
		color, spin = AMBER, true
		lit = math.floor(t * 4) % 2 == 0 -- blink during the join window
	elseif state == "PLAYING" or state == "ARM IN USE" then
		color, lit, spin = AMBER, true, true
	end

	for _, p in { light, beacon } do
		p.Color = if lit then color else (if state == "COMING SOON" then GREY else color:Lerp(Color3.new(0, 0, 0), 0.6))
		p.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
	end

	beaconHome[beacon] = beaconHome[beacon] or beacon.CFrame
	local home = beaconHome[beacon]
	local yaw = if spin then t * 4 else 0
	beacon.CFrame = CFrame.new(home.Position) * CFrame.Angles(0, yaw, 0) * (home - home.Position)
	local sweep = beacon:FindFirstChild("BeaconSweep")
	if sweep then
		sweep.Color = color
		sweep.Brightness = if spin and lit then 3 else 0
	end

	local holder = bay:FindFirstChild("Visual") and bay.Visual:FindFirstChild("TunnelLightHolder")
	local tunnelLight = holder and holder:FindFirstChild("TunnelLight")
	if tunnelLight then
		tunnelLight.Color = color
		tunnelLight.Brightness = if state == "COMING SOON" then 0.2 else 1.2
	end
end

local led = arm:WaitForChild("Shoulder"):WaitForChild("StatusLED")

-- Heartbeat rather than RenderStepped so the lights keep updating while Studio is unfocused.
RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for _, bay in bays:GetChildren() do
		updateBay(bay, t)
	end
	local online = arcadeState:GetAttribute("ArmOnline") == true
	led.Color = if online then GREEN else LED_OFF
	led.Material = if online then Enum.Material.Neon else Enum.Material.SmoothPlastic
end)
