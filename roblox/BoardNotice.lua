--!strict
-- An on-screen notice for when the board stops updating, and why.
--
-- The board is read by a vision model on the robot laptop (see `bridge/board.py`). When that
-- read fails, nothing in Roblox looks broken: the Sky Arm keeps mirroring the real arm, the
-- platforms keep standing exactly where they were, and the only symptom is that blocks never
-- move again. From inside the game that is indistinguishable from nobody having touched the
-- cubes for a while.
--
-- One of the causes is worth interrupting the game for: the **OpenAI account running out of
-- credits**. The key is fine, the camera is fine, the code is fine, and somebody standing next
-- to the rig can fix it in about a minute - but only if they are told. So that one gets a
-- red banner naming the fix, and the softer failures get a yellow one that says it will
-- clear on its own.
--
--   local BoardNotice = require(script.Parent.BoardNotice)
--   local notice = BoardNotice.new()
--   Bridge.onState(function(s) notice:update(s.notes and s.notes.board) end)
--
-- Called every frame; it only touches the GUI when the message actually changes.

local Players = game:GetService("Players")

local BoardNotice = {}
BoardNotice.__index = BoardNotice

local RED = Color3.fromRGB(104, 32, 36)
local AMBER = Color3.fromRGB(86, 66, 18)

-- Keyed by `notes.board.state`, which is `BoardUnavailable.kind` on the Python side. A state
-- that is not in here - "ok", "reading", "waiting" - shows nothing at all.
local MESSAGES: { [string]: { title: string, body: string, bad: boolean } } = {
	no_credits = {
		title = "Board frozen: OpenAI credits exhausted",
		body = "Blocks will not move until the robot laptop's OpenAI account is topped up. "
			.. "The arm still works. Add credits and the read retries on its own.",
		bad = true,
	},
	no_key = {
		title = "Board unavailable: no OpenAI API key",
		body = "The robot laptop has no OPENAI_API_KEY, so the real blocks are never read. "
			.. "Set it and restart the bridge.",
		bad = true,
	},
	auth = {
		title = "Board frozen: OpenAI rejected the API key",
		body = "Blocks are stuck at the last board that was read. Check the key on the robot "
			.. "laptop and restart the bridge.",
		bad = true,
	},
	rate_limit = {
		title = "Board behind: rate-limited by OpenAI",
		body = "This clears by itself in a few seconds.",
		bad = false,
	},
	error = {
		title = "Board read failed",
		body = "Usually the overhead camera. The read retries in about 20 seconds.",
		bad = false,
	},
}

function BoardNotice.new()
	local self = setmetatable({}, BoardNotice)
	self.shown = nil :: string?
	self.guis = {} :: { [Player]: { frame: Frame, title: TextLabel, body: TextLabel } }
	Players.PlayerAdded:Connect(function(player)
		-- A player who joins while the board is already broken has to be told too, so the
		-- current state is re-applied as soon as their GUI exists.
		local state = self.shown
		self.shown = nil
		if state then
			self:render(state)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		self.guis[player] = nil
	end)
	return self
end

function BoardNotice.build(self, player: Player)
	local parent = player:FindFirstChildOfClass("PlayerGui")
	if not parent then
		return nil
	end

	local screen = Instance.new("ScreenGui")
	screen.Name = "BoardNotice"
	screen.ResetOnSpawn = false          -- a respawn must not clear a warning that still holds
	screen.DisplayOrder = 100
	screen.Parent = parent

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 72)
	frame.BackgroundColor3 = RED
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = screen

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -32, 0, 24)
	title.Position = UDim2.new(0, 16, 0, 10)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 17
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	local body = Instance.new("TextLabel")
	body.Size = UDim2.new(1, -32, 0, 32)
	body.Position = UDim2.new(0, 16, 0, 34)
	body.BackgroundTransparency = 1
	body.Font = Enum.Font.Gotham
	body.TextSize = 13
	body.TextColor3 = Color3.fromRGB(226, 216, 216)
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextWrapped = true
	body.Parent = frame

	local entry = { frame = frame, title = title, body = body }
	self.guis[player] = entry
	return entry
end

function BoardNotice.render(self, state: string?)
	if state == self.shown then
		return                           -- nothing changed; do not touch the GUI every frame
	end
	self.shown = state
	local msg = state and MESSAGES[state]

	for _, player in ipairs(Players:GetPlayers()) do
		local entry = self.guis[player] or self:build(player)
		if entry then
			if msg then
				entry.frame.BackgroundColor3 = msg.bad and RED or AMBER
				entry.title.Text = msg.title
				entry.body.Text = msg.body
				entry.frame.Visible = true
			else
				entry.frame.Visible = false
			end
		end
	end

	if msg then
		-- Also to the server log, because during a demo the person who can fix this is more
		-- likely to be looking at Studio's output than at a player's screen.
		warn(("[BoardNotice] %s - %s"):format(msg.title, msg.body))
	end
end

-- `note` is `state.notes.board`, as sent by bridge/producers/board.py.
function BoardNotice.update(self, note: any)
	local state = nil :: string?
	if typeof(note) == "table" and MESSAGES[tostring(note.state)] then
		state = tostring(note.state)
	end
	self:render(state)
end

return BoardNotice
