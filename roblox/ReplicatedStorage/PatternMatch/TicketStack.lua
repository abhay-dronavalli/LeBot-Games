-- ReplicatedStorage.PatternMatch.TicketStack
-- The small shared rules of the HUD's ticket stack (bottom left), used by the server (Game:cycleTicket)
-- and the client (StarterGui.PatternHud), so both agree:
--   - the rail order stays oldest first; the ACTIVE ticket is just the one shown face up on top;
--   - cycling moves the active ticket one step forward or back through that order, wrapping around;
--   - Q cycles back, E cycles forward, and so do the < and > arrow buttons beside the stack;
--   - the "+N waiting" badge counts every ticket but the active one; at most 3 waiting cards peek out.

local TicketStack = {}

TicketStack.KEYS = { [Enum.KeyCode.Q] = -1, [Enum.KeyCode.E] = 1 }
TicketStack.ARROWS = { Prev = -1, Next = 1 }
TicketStack.MAX_EDGES = 3

-- ids: ticket ids oldest first. The id `dir` steps (+1 / -1) from activeId, wrapping around; activeId
-- itself when there is nothing else to cycle to. nil for an empty list.
function TicketStack.cycledId(ids, activeId, dir)
	local n = #ids
	if n == 0 then
		return nil
	end
	local index = table.find(ids, activeId) or 1
	return ids[(index - 1 + dir) % n + 1]
end

-- Tickets waiting behind the active one.
function TicketStack.waitingCount(ticketCount)
	return math.max(0, ticketCount - 1)
end

-- The badge text, or nil to hide the badge.
function TicketStack.badgeText(waiting)
	return waiting > 0 and string.format("+%d waiting", waiting) or nil
end

-- Waiting cards drawn as edges peeking out behind the active one.
function TicketStack.pileEdges(waiting)
	return math.min(TicketStack.MAX_EDGES, waiting)
end

return TicketStack
