-- GhostControl -- Q toggles debug ghost mode: fly through the whole course, nothing can kill
-- you. WASD moves relative to the camera, Space rises, Shift drops, hold E for a speed boost.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GhostToggle = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GhostToggle")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local BASE_SPEED = 55
local BOOST_SPEED = 130

local ghost = false

-- on-screen state readout
local gui = Instance.new("ScreenGui")
gui.Name = "GhostHud"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local badge = Instance.new("TextLabel")
badge.Size = UDim2.new(0, 330, 0, 26)
-- Below the debug scenario panel, which occupies the top-left corner.
badge.Position = UDim2.new(0, 16, 0, 428)
badge.BackgroundTransparency = 0.25
badge.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
badge.Font = Enum.Font.SourceSansBold
badge.TextSize = 15
badge.TextColor3 = Color3.fromRGB(190, 190, 200)
badge.Text = "Q = GHOST MODE (fly + invincible)  -  OFF"
badge.Parent = gui

local function setBadge()
	if ghost then
		badge.Text = "GHOST ON  -  WASD fly, Space up, Shift down, E boost, Q off"
		badge.TextColor3 = Color3.fromRGB(120, 240, 150)
	else
		badge.Text = "Q = GHOST MODE (fly + invincible)  -  OFF"
		badge.TextColor3 = Color3.fromRGB(190, 190, 200)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q then
		GhostToggle:FireServer()
	end
end)

-- server confirms the authoritative state
GhostToggle.OnClientEvent:Connect(function(on)
	ghost = on
	setBadge()

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		-- PlatformStand stops the walk/fall state machine fighting the fly movement
		hum.PlatformStand = on
	end
end)

RunService.RenderStepped:Connect(function(dt)
	if not ghost then
		return
	end

	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end

	local cam = workspace.CurrentCamera
	if not cam then
		return
	end

	local dir = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.new(0, 1, 0) end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then dir -= Vector3.new(0, 1, 0) end

	-- hold still in the air rather than falling when no key is held
	hrp.AssemblyLinearVelocity = Vector3.zero
	if dir.Magnitude > 0 then
		local speed = UserInputService:IsKeyDown(Enum.KeyCode.E) and BOOST_SPEED or BASE_SPEED
		hrp.CFrame = hrp.CFrame + dir.Unit * speed * dt
	end
end)

setBadge()
