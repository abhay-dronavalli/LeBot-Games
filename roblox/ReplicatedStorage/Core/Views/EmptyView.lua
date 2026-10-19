-- ReplicatedStorage.Core.Views.EmptyView
-- A view that shows nothing, for games whose own client scripts already draw that role's screen (Rising
-- Flood's player HUD is StarterPlayerScripts.FloodClient). RoleClient still sets the role's camera.

local EmptyView = {}

function EmptyView.enter() end

function EmptyView.exit() end

return EmptyView
