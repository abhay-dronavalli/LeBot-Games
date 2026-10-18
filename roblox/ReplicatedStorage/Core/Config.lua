-- ReplicatedStorage.Core.Config
-- Core tunables shared by every game: roles and the robot station. See docs/roles.md.

return {
	-- testing: "player" or "robot" gives the first client to join that role (solo Play testing); nil assigns
	-- normally (first client = player, second = robot, everyone after = spectator)
	debugForceRole = nil,
	roleSwapKey = Enum.KeyCode.F8,       -- debug: any window swaps the player and robot roles (Studio only)
	viewSyncHz = 20,                     -- player camera -> spectators, samples per second
	-- Lobby robot view: a slow orbit over the room, in world studs
	lobbyOrbit = { center = Vector3.new(0, 6, -29), radius = 30, height = 18, seconds = 90 },
}
