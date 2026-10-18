-- ReplicatedStorage.Core.Config
-- Core tunables shared by every game: roles and the robot station. See docs/roles.md.

return {
	-- testing: "player" or "robot" gives the first client to join that role (solo Play testing); nil assigns
	-- normally (first client = player, second = robot, everyone after = spectator)
	debugForceRole = nil,
	roleSwapKey = Enum.KeyCode.F8,       -- debug: any window swaps the player and robot roles (Studio only)
	viewSyncHz = 20,                     -- player camera -> spectators, samples per second
	-- Lobby robot view (Core.Views.LobbyRobotView): the camera swings around `center` (world studs) at
	-- `radius`, `height` above it, looking at it, once round in `seconds`. `arc` = {from, to} in degrees
	-- (0 = +X, 90 = +Z) swings it back and forth along that arc instead (there and back in `seconds`).
	-- Workshop: the wall arm (back wall, -Z) and the table, seen from the room side; checked with raycasts
	-- to stay inside the shell, under the ceiling lamps, with nothing between it and the arm and table.
	-- CoreRoles streams the robot and spectators around `center` (Workspace.RoleStreamFocus).
	lobbyOrbit = { center = Vector3.new(400, 32, 252), radius = 56, height = 20, seconds = 60, arc = { 25, 155 } },
}
