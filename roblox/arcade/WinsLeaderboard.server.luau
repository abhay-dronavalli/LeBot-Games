-- Studio location: ServerScriptService.WinsLeaderboard (Script)
--[[
	WinsLeaderboard: lists EVERY player in the server and their Wins on the board on the
	workshop's front wall (Workshop.Front.WinsLeaderboard). It only reads leaderstats.Wins
	(created and awarded by ArcadeManager), so ArcadeManager doesn't need to know about it.
	Rows shrink to fit as more players join.
]]

local Players = game:GetService("Players")

local board = workspace:WaitForChild("Workshop"):WaitForChild("Front"):WaitForChild("WinsLeaderboard"):WaitForChild("Board")
local rows = board:WaitForChild("SurfaceGui"):WaitForChild("Rows")
local empty = rows:WaitForChild("Empty")

local MAX_ROW, MIN_ROW, PAD = 26, 10, 3
local GOLD = Color3.fromRGB(245, 197, 24)
local SILVER = Color3.fromRGB(200, 205, 215)
local BRONZE = Color3.fromRGB(205, 127, 50)
local WHITE = Color3.fromRGB(240, 240, 235)
local TILE = Color3.fromRGB(34, 35, 40)

local function winsOf(p)
	local ls = p:FindFirstChild("leaderstats")
	local w = ls and ls:FindFirstChild("Wins")
	return if w then w.Value else 0
end

local function makeRow(i)
	local row = Instance.new("Frame")
	row.Name = "Row" .. i
	row.LayoutOrder = i
	row.BorderSizePixel = 0
	row.BackgroundColor3 = TILE
	row.BackgroundTransparency = if i % 2 == 0 then 0.5 else 0
	local function lbl(name, x, w, align)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Position = UDim2.new(x, 0, 0.1, 0)
		l.Size = UDim2.new(w, 0, 0.8, 0)
		l.Font = Enum.Font.RobotoMono
		l.TextScaled = true
		l.TextXAlignment = align
		l.TextColor3 = WHITE
		l.Parent = row
	end
	lbl("Rank", 0.02, 0.1, Enum.TextXAlignment.Left)
	lbl("PlayerName", 0.12, 0.6, Enum.TextXAlignment.Left)
	lbl("Wins", 0.75, 0.23, Enum.TextXAlignment.Right)
	row.Parent = rows
	return row
end

local function refresh()
	local list = Players:GetPlayers()
	table.sort(list, function(a, b)
		local wa, wb = winsOf(a), winsOf(b)
		if wa ~= wb then
			return wa > wb
		end
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)

	local n = #list
	local h = if n == 0 then MAX_ROW else math.clamp(math.floor((rows.AbsoluteSize.Y + PAD) / n) - PAD, MIN_ROW, MAX_ROW)
	if rows.AbsoluteSize.Y <= 0 then
		h = math.clamp(math.floor(210 / math.max(n, 1)) - PAD, MIN_ROW, MAX_ROW)
	end

	-- players sharing a win count share a rank
	local rank, lastWins = 0, nil
	for i, p in list do
		local w = winsOf(p)
		if w ~= lastWins then
			rank, lastWins = i, w
		end
		local row = rows:FindFirstChild("Row" .. i) or makeRow(i)
		row.Size = UDim2.new(1, 0, 0, h)
		local color = if w == 0 then WHITE elseif rank == 1 then GOLD elseif rank == 2 then SILVER elseif rank == 3 then BRONZE else WHITE
		row.Rank.Text = tostring(rank)
		row.PlayerName.Text = p.DisplayName
		row.Wins.Text = tostring(w)
		for _, l in { row.Rank, row.PlayerName, row.Wins } do
			l.TextColor3 = color
		end
	end
	for _, row in rows:GetChildren() do
		local i = tonumber(row.Name:match("^Row(%d+)$"))
		if i and i > n then
			row:Destroy()
		end
	end
	empty.Visible = n == 0
end

local function watch(p)
	task.spawn(function()
		local ls = p:WaitForChild("leaderstats", 30)
		local w = ls and ls:WaitForChild("Wins", 30)
		if w then
			w.Changed:Connect(refresh)
		end
		refresh()
	end)
	refresh()
end

Players.PlayerAdded:Connect(watch)
Players.PlayerRemoving:Connect(function()
	task.delay(0.5, refresh) -- once the player is out of GetPlayers()
end)
for _, p in Players:GetPlayers() do
	watch(p)
end
refresh()
