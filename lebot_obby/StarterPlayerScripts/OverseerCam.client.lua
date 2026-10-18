-- OverseerCam (client) -- player 2's view of the bay.
--
-- The overseer's job is to put real cubes on a real mat and have them land in the right cells.
-- That needs a view where the 4x3 grid is legible and the obstacle is visible at the same
-- time, which the runner's over-the-shoulder camera is not.
--
-- **V** toggles it. In solo mode one person flips between the two views to check what the
-- other half of the game looks like; with two players, player 2 simply leaves it on.
--
-- WHY THIS ANGLE. Elevated, from the entrance end, looking down the bay:
--
--   * Columns (X) spread left-to-right and rows (Z) recede, which is exactly how the 4x3
--     debug grid and the printed mat are laid out. A side-on view would foreshorten the
--     columns and make "col 2, row 1" guesswork.
--   * It is where the Sky Arm stands, so what the overseer sees and what the arm reaches
--     share a mental model.
--   * High enough (y ~ 38) to clear a bay's own furniture -- bay 1's 16-stud saw wall and side
--     walls -- while staying under the roof trusses at 46.
--
-- WALLS. The warehouse shell sits between this camera and the bay, so the shell goes
-- transparent while the view is on. Crucially that is done CLIENT-SIDE: it is this viewer's
-- problem, not a change to the world, so player 1 still sees solid walls around them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local DebugStatus = Remotes:WaitForChild("DebugStatus")
local DebugCommand = Remotes:WaitForChild("DebugCommand")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CELL = Config.CellSize
local HEIGHT = 38          -- above a bay's tallest furniture, below the roof trusses
local SETBACK = 13         -- studs behind the entrance edge

-- Client-created instances never replicate, so a folder in Workspace is private to this
-- viewer -- and unlike parenting under CurrentCamera, a BillboardGui adorned to a part in here
-- actually renders. The cell numbers were invisible until this moved.
local overlay = Instance.new("Folder")
overlay.Name = "OverseerOverlay"
overlay.Parent = Workspace

local active = false
local activeBay = Config.LiveBay or 1
local solveCells, bayName = nil, "?"
local markers = {}
local hidden = {}          -- part -> its real transparency, so it can be put back

----------------------------------------------------------------
-- HUD
----------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "OverseerCam"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = playerGui

local banner = Instance.new("TextLabel")
banner.AnchorPoint = Vector2.new(0.5, 0)
banner.Position = UDim2.new(0.5, 0, 0, 10)
banner.Size = UDim2.new(0, 460, 0, 30)
banner.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
banner.BackgroundTransparency = 0.12
banner.BorderSizePixel = 0
banner.Font = Enum.Font.GothamBold
banner.TextSize = 15
banner.TextColor3 = Color3.fromRGB(120, 200, 255)
banner.Text = "OVERSEER VIEW"
banner.Parent = gui
Instance.new("UICorner", banner).CornerRadius = UDim.new(0, 6)

local sub = Instance.new("TextLabel")
sub.AnchorPoint = Vector2.new(0.5, 0)
sub.Position = UDim2.new(0.5, 0, 0, 42)
sub.Size = UDim2.new(0, 460, 0, 18)
sub.BackgroundColor3 = Color3.fromRGB(14, 18, 28)
sub.BackgroundTransparency = 0.25
sub.BorderSizePixel = 0
sub.Font = Enum.Font.Gotham
sub.TextSize = 12
sub.TextColor3 = Color3.fromRGB(176, 186, 202)
sub.Text = "V returns to the runner"
sub.Parent = gui
Instance.new("UICorner", sub).CornerRadius = UDim.new(0, 5)

----------------------------------------------------------------
-- Cell markers: a label per cell, so a called-out "(1,0)" is a place you can see
----------------------------------------------------------------
local function clearMarkers()
	for _, m in ipairs(markers) do
		if m then
			m:Destroy()
		end
	end
	table.clear(markers)
end

local function wantedSet()
	local want = {}
	for _, c in ipairs(solveCells or {}) do
		want[c[1] .. "," .. c[2]] = true
	end
	return want
end

local function buildMarkers()
	clearMarkers()
	local bay = Workspace.Warehouse:FindFirstChild(("Bay%02d"):format(activeBay))
	local anchors = bay and bay:FindFirstChild("CrateAnchors")
	if not anchors then
		return
	end
	local want = wantedSet()

	for col = 0, Config.BayCols - 1 do
		for row = 0, Config.BayRows - 1 do
			local a = anchors:FindFirstChild(("Cell_%d_%d"):format(col, row))
			if a then
				local key = col .. "," .. row
				local isWanted = want[key]

				local pad = Instance.new("Part")
				pad.Name = "OverseerCell_" .. key
				pad.Anchored = true
				pad.CanCollide = false
				pad.CanQuery = false
				pad.CanTouch = false
				pad.Size = Vector3.new(CELL - 1.2, 0.08, CELL - 1.2)
				pad.CFrame = CFrame.new(a.Position + Vector3.new(0, 0.1, 0))
				pad.Material = Enum.Material.Neon
				pad.Transparency = isWanted and 0.35 or 0.86
				pad.Color = isWanted and Color3.fromRGB(90, 230, 130)
					or Color3.fromRGB(90, 130, 190)
				-- client-side only: the runner must not see the operator's overlay
				pad.Parent = overlay
				table.insert(markers, pad)

				-- Painted flat on the cell, not floating above it.
				--
				-- This was a BillboardGui first and it simply did not render -- the label
				-- existed with the right text and a laid-out AbsoluteSize, but nothing
				-- appeared. A SurfaceGui on the top face is part of the world, so it is
				-- certain to draw, and for a view looking straight down a number lying flat
				-- on the floor reads more like a painted bay marking anyway.
				local sg = Instance.new("SurfaceGui")
				sg.Face = Enum.NormalId.Top
				sg.AlwaysOnTop = false
				sg.LightInfluence = 0
				sg.PixelsPerStud = 36
				sg.Adornee = pad
				sg.Parent = pad

				local t = Instance.new("TextLabel")
				t.AnchorPoint = Vector2.new(0.5, 0.5)
				t.Position = UDim2.new(0.5, 0, 0.5, 0)
				t.Size = UDim2.new(0.62, 0, 0.42, 0)
				t.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
				t.BackgroundTransparency = isWanted and 0.1 or 0.32
				t.BorderSizePixel = 0
				t.Font = Enum.Font.GothamBold
				-- A Top-face SurfaceGui's own axes run across the bay, so the number comes
				-- out reading bottom-to-top. Turn it to face the overseer camera, which
				-- always looks down the bay from the entrance end.
				t.Rotation = -90
				t.TextScaled = true
				t.TextColor3 = isWanted and Color3.fromRGB(130, 255, 170)
					or Color3.fromRGB(220, 228, 240)
				t.Text = ("%d,%d"):format(col, row)
				t.Parent = sg
				Instance.new("UICorner", t).CornerRadius = UDim.new(0.18, 0)
				local ts = Instance.new("UIStroke", t)
				ts.Color = isWanted and Color3.fromRGB(70, 200, 120)
					or Color3.fromRGB(80, 92, 112)
				ts.Thickness = 2
			end
		end
	end
end

----------------------------------------------------------------
-- Walls. Client-side only, so this is one viewer's x-ray and not a change to the world.
----------------------------------------------------------------
local function ghostWalls(on)
	if on then
		local shell = Workspace.Warehouse:FindFirstChild("Shell")
		for _, p in ipairs(shell and shell:GetChildren() or {}) do
			if p:IsA("BasePart") and hidden[p] == nil then
				hidden[p] = p.LocalTransparencyModifier
				p.LocalTransparencyModifier = 0.92
			end
		end
	else
		for p, v in pairs(hidden) do
			if p and p.Parent then
				p.LocalTransparencyModifier = v
			end
		end
		table.clear(hidden)
	end
end

----------------------------------------------------------------
-- The view itself
----------------------------------------------------------------
local function aimCamera()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local zStart = (activeBay - 1) * Config.BayPitch
	local midX = Config.BayWidth / 2
	local eye = Vector3.new(midX, HEIGHT, zStart - SETBACK)
	local look = Vector3.new(midX, 1, zStart + Config.BayDepth * 0.55)
	cam.CFrame = CFrame.lookAt(eye, look)
end

local function setActive(on)
	active = on
	gui.Enabled = on
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if on then
		cam.CameraType = Enum.CameraType.Scriptable
		ghostWalls(true)
		buildMarkers()
		aimCamera()
	else
		clearMarkers()
		ghostWalls(false)
		cam.CameraType = Enum.CameraType.Custom
		local ch = player.Character
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
	end
end

local function refreshBanner()
	banner.Text = ("OVERSEER VIEW   -   BAY %02d   -   %s"):format(activeBay, bayName:upper())
	local n = #(solveCells or {})
	sub.Text = (n > 0)
		and ("green cells want a block  (%d marked)   -   V returns to the runner"):format(n)
		or "this bay is cleared by an action, not by filling cells   -   V returns to the runner"
end

DebugStatus.OnClientEvent:Connect(function(status)
	local changed = status.activeBay ~= activeBay
	activeBay = status.activeBay or activeBay
	local info = status.bays and status.bays[activeBay]
	solveCells = info and info.solveCells or nil
	bayName = info and info.obstacle or "?"
	refreshBanner()
	if active then
		-- the bay moved under us, or a solve changed which cells matter
		buildMarkers()
		if changed then
			aimCamera()
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.V then
		return
	end
	setActive(not active)
end)

-- The camera is re-created on respawn, which silently drops Scriptable and the overlay with
-- it; re-assert rather than leaving the overseer staring through their own character.
player.CharacterAdded:Connect(function()
	task.wait(0.4)
	if active then
		setActive(true)
	end
end)

RunService.RenderStepped:Connect(function()
	if active then
		aimCamera()
	end
end)

DebugCommand:FireServer("status")
print("[OverseerCam] V toggles the overseer view")
