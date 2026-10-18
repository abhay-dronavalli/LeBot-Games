-- BlockSync -- nothing else in the game hard-codes a world position. cellToWorld reads the
-- Cell_c_r anchor parts baked into each bay prefab, so moving a bay moves everything with it.
local BlockSync = {}

function BlockSync.cellToWorld(bayModel, col, row)
	local anchorsFolder = bayModel:FindFirstChild("CrateAnchors")
	if not anchorsFolder then
		error(string.format("BlockSync.cellToWorld: %s has no CrateAnchors folder", bayModel:GetFullName()))
	end

	local anchorName = string.format("Cell_%d_%d", col, row)
	local anchor = anchorsFolder:FindFirstChild(anchorName)
	if not anchor then
		error(string.format("BlockSync.cellToWorld: missing anchor %s under %s", anchorName, bayModel:GetFullName()))
	end

	return anchor.CFrame
end

return BlockSync
