# Arcade Lobby Build Plan

Oct 17, 2026 · @Madhu

The lobby is an arcade floor. Every game is a glowing cabinet with a portal: you walk in to play, and every game you win adds 1 to your **Wins** score. Everything lives in one place file (`Place1.rbxl`) because the robot WebSocket only works in Studio.

## Goal

Done means:

- Walk into a portal, a short join window opens, the game loads, and everyone returns to the arcade when it ends
- Only one game runs at a time, because there is only one real arm
- Winning a game adds 1 to your Wins, and Wins unlock the hardest cabinet
- Any teammate's game plugs in by following one module contract
- Nothing from a finished game (effects, loops, parts) leaks into the next one

## The arcade floor

A neon arcade hall with the Sky Arm hanging from the ceiling like a giant claw-machine claw, cabinets in a ring around it, and a scoreboard by the spawn.

| Feature | What it does | Priority |
|---|---|---|
| Game cabinets + portals | One cabinet per game (Obby, Flood, Red Light Green Light, Arena), each with a marquee sign and a portal that ripples like water when you walk through | Must |
| Cabinet screens | Each screen shows READY, STARTING (with the join countdown), ARM IN USE, or LOCKED (with the wins needed) | Must |
| Sky Arm claw | Giant arm on the ceiling mirrors the real follower live | Must |
| Wins in the player list | `leaderstats.Wins` shows everyone's score with no extra UI work | Must |
| High score board | Big arcade screen showing the players with the most wins | Should |
| DON'T PRESS button | Shakes the hall and sends an earthquake to the real arm | Should |
| Lobby sandbox | Real blocks on the table spawn as platforms on the arcade floor, so waiting players have something to do | Should |
| Spectator screen | Players not in the current game watch it live on a big SurfaceGui screen | Nice |
| Vibe pass | Dark hall, neon trim, Bloom, arcade music with a hype track during the join countdown | Nice |

The arcade map stays in Workspace. Each game map stays in `ServerStorage.Modes` until its portal loads it, so only one game map exists at a time.

## Portal flow

One server Script, `ArcadeManager`, owns every portal. A single `busy` flag makes sure only one game runs at a time.

While a game runs, every other cabinet shows ARM IN USE, and players left in the arcade can watch on the spectator screen.

The portals are checked 4 times a second for characters inside them, not with `Touched`, because `Touched` misses players who teleport in or stand still in the portal during the join window. The flow for one game (simplified from `ArcadeManager`):

```lua
local function onPortal(cab, player)
	if not modules[cab.Name] or isLocked(cab, player) then return end
	if busy then
		if joinCabinet == cab then addToJoined(player) end -- joins during the 10 s window
		return
	end
	busy = true -- set before anything yields, so a second player returns early
	task.spawn(runGame, cab, player)
end

local function runGame(cab, firstPlayer)
	local players = runJoinWindow(cab, firstPlayer, 10)
	local mode = modules[cab.Name]
	Bridge.send({t = "mode", name = cab.Name:lower()})
	pcall(mode.Start, players)

	-- timeout so a broken game can't freeze the arcade
	local results = waitWithTimeout(mode.Finished, 180)

	pcall(mode.Stop)
	Bridge.send({t = "mode", name = "lobby"})
	returnPlayersToArcade(players)
	awardWins(results)

	setScreens("READY")
	busy = false
end
```

## Scoring: games won

The only score is **Wins**: the number of games a player has won. There are no tickets, bonuses, or points.

- Win a game: **+1 Win**
- Lose, leave early, or the game times out: **+0**
- Each game defines what "won" means (see [Rising Flood](#rising-flood-the-game-we-have)). The arcade is the only thing that changes the score. Games just report who won.
- **Arena stays locked until a player has 3 Wins.** Every other cabinet is open from the start.

```lua
local function awardWins(results, played)
	for _, r in results do
		-- only players who were actually in this game can win it
		if r.won and played[r.player] and r.player.Parent then
			r.player.leaderstats.Wins.Value += 1
		end
	end
end
```

`leaderstats` is created in `Players.PlayerAdded` with a single IntValue named `Wins`, so the Roblox player list shows it automatically. The high score board sorts players by `Wins`.

Wins reset when the Studio session ends. Saving them needs DataStores and a published place, so that waits until after the hackathon.

## Mode contract (send to teammates today)

Every game is a Folder in `ServerStorage.Modes`, named exactly like its portal. It holds the game's map Model and a ModuleScript called `Module` that returns this shape:

```lua
local Mode = {}
Mode.DisplayName = "Rising Flood"
Mode.Tip = "Stay above the water!"
Mode.WinsToUnlock = 0 -- 3 for Arena
Mode.Finished = Instance.new("BindableEvent")

function Mode.Start(players)
	-- clone map into workspace, move players in, start loops
end

function Mode.Stop()
	-- destroy map, disconnect every connection, clear effects
end

return Mode
```

When the game ends, fire `Finished` once, with a **list** that has one entry per player who played:

```lua
Mode.Finished:Fire({
	{player = player1, won = true},
	{player = player2, won = false},
})
```

Use the list form, not `{[player1] = {...}}`. A BindableEvent turns Player keys into strings, so the arcade couldn't tell who won (tested in Studio).

Rules:

- Never open your own WebSocket. Read arm and block data from the shared `StateStore` (`ServerStorage.Shared.StateStore`), and send events through the shared `Bridge` (`ServerStorage.Shared.Bridge`)
- Set your map Model's `ModelStreamingMode` to **Persistent**. The place has streaming on, so otherwise clients may not have your map's parts yet when your scripts look for them
- Show your own win/lose screen, then fire `Finished`. The arcade sends players back as soon as it hears `Finished`
- Never touch `leaderstats`; just report who won
- Track every connection in a table and disconnect all of them in `Stop()`
- Don't touch Workspace outside your own map, and don't send players back yourself; the arcade does that
- Don't change `Lighting`; the arcade owns it
- Fire `Finished` exactly once, even if everyone dies or leaves
- Test alone in your own place file with a fake arcade that just calls `Start`, then `Stop`

## Robot bridge in the arcade

The arcade owns the only Bridge connection, so it is also where the robot side gets reset between games.

- **On load:** Bridge connects once when the server starts. If it drops, it retries every 2 seconds and the cabinet screens show "ARM OFFLINE" instead of the game crashing
- **Mode messages:** send `{t="mode", name=...}` on every switch. Python swaps the table mapping to that game's build zone, and clears all arm effects when it hears `lobby`
- **Sky Arm claw:** the arcade rig reads `StateStore` every Heartbeat. Games can reuse it or hide it
- **DON'T PRESS:** sends `{t="event", name="earthquake", intensity=0.5, duration=3}`. It's disabled while a game is running and has a 20-second cooldown, so nobody spams the real servos
- **Mock mode:** build the arcade against `python -m server.main --mock` so you never wait on hardware

## Build order

Plumbing first, water features last. Each step leaves something you can demo.

- [ ] 1. **Send the contract** (30 min): post the mode contract to the team chat before anyone writes more game code
- [x] 2. **Arcade hall**: spawn, 4 cabinets with marquees, portals and status screens, scoreboard, how-to-play sign
- [x] 3. **Portal flow**: join window, busy lock, 3-minute timeout, return to the arcade, and `Stop` cleanup, tested with Flood in place of a dummy game
- [x] 4. **Plug in Flood**: first real game through the contract (see [the porting list](#porting-flood-to-the-contract))
- [x] 5. **Wins + Arena lock**: `leaderstats.Wins`, scoreboard, LOCKED screen showing how many more wins *you* need
- [ ] 6. **Sky Arm claw**: rig is on the ceiling and idles on its own; still needs checking against the real arm (signs and offsets per joint are in `CAL` at the top of the Sky Arm section in `ArcadeClient`)
- [x] 7. **High score board + DON'T PRESS**
- [ ] 8. **Vibe pass**: neon, marquees, shimmering portals and indoor lighting are done. Still open: music, spectator screen, lobby sandbox

## What's in Studio (`Place1.rbxl`)

The lobby is now a daylit robotics workshop (`Workspace.Workshop`); the old neon arcade is kept in `ServerStorage.OldLobbyBackup`.

| Piece | Where |
|---|---|
| Room: floor, walls, columns, trusses, skylights, pipes | `Workspace.Workshop.Shell` |
| Ceiling lamps | `Workspace.Workshop.Lighting` |
| Arm mount, chalkboards + whiteboard (the real math), HIGH SCORES board, project sign | `Workspace.Workshop.BackWall` |
| Wall-mounted arm (driven by `ArcadeClient`; link lengths + idle motion are attributes on the model) | `Workspace.Workshop.WallArm` |
| Giant table (`LobbyBuildZone`) + placeholder cubes | `Workspace.Workshop.Table` |
| Game bays (each folder has a `Mode` attribute) | `Workspace.Workshop.Bays.Bay1_Obby`, `Bay2_RisingFlood`, `Bay3_RedLightGreenLight`, `Bay4_Arena` |
| Spawn, return points, parts counter, E-stop, water cooler | `Workspace.Workshop.Front` |
| WINS LEADERBOARD board on the front wall, beside the parts counter (lists every player in the server) | `Workspace.Workshop.Front.WinsLeaderboard` |
| Benches, printer, crates, signs, sticky notes, vents | `Workspace.Workshop.Props` |
| Portal flow, Wins, scoreboard, E-stop, arm feed | `ServerScriptService.ArcadeManager` |
| Bay screens, banners, shake, arm animation | `StarterPlayer.StarterPlayerScripts.ArcadeClient` |
| Bay status lights, beacons, tunnel lights, arm LED | `StarterPlayer.StarterPlayerScripts.WorkshopClient` |
| Characters scaled 1.5× (jump and walk speed stay at the defaults) | `ServerScriptService.CharacterScale` |
| Fills the WINS LEADERBOARD from `leaderstats.Wins` (ties share a rank; top 3 are gold/silver/bronze; rows shrink to fit) | `ServerScriptService.WinsLeaderboard` |
| Robot connection + shared state | `ServerStorage.Shared.Bridge`, `ServerStorage.Shared.StateStore` |
| Games | `ServerStorage.Modes.<ModeName>` (`Map` + `Module`) |
| Arcade state for clients | `ReplicatedStorage.Arcade` (attributes, `ArcadeFx` remote, `Arm` joint angles) |

Repo copies of every script are in `roblox/` (`arcade/`, `shared/`, `modes/Flood/`, `flood/`). Studio is the source of truth.

A bay becomes playable on its own: drop a mode Folder named after the bay's `Mode` attribute (`Obby`, `RedLight`, `Arena`) into `ServerStorage.Modes` and its screen and light switch from COMING SOON to READY on the next play (Arena shows LOCKED until a player has 3 wins).

## Merge checklist

Merge each game as soon as it works, not all at once at the end.

- [ ] Teammate exports their game Folder as `.rbxm` (right click → Save to File)
- [ ] Drop it into `ServerStorage.Modes` and add a cabinet + portal with the same name
- [ ] Play it 3 times in a row, then 3 times mixed with other games
- [ ] Check that Wins went up only for winners, and that the arm is calm back in the arcade
- [ ] Check the Output window for errors after each game

## Risks

| Risk | Fix |
|---|---|
| Two players hit different portals at the same moment | `busy` flag is set before anything yields, so the second touch returns |
| A game never fires `Finished` | 3-minute timeout in the flow; nobody gets a win |
| Leftover effects carry into the next game | Arcade sends `mode: lobby`; Python clears all effects when it gets it |
| Two games use the same object names or RemoteEvents | Every game keeps its stuff inside its own Folder (`ReplicatedStorage.<Mode>` for remotes) |
| Players spawn inside parts on return | Return them to fixed spawn points in the arcade, not their old position |
| Bridge drops mid-demo | Auto retry plus ARM OFFLINE screens; games are still playable without the arm |

---

# Rising Flood (the game we have)

**Status:** playable from the arcade's RISING FLOOD cabinet in `Place1.rbxl`, following the mode contract. It runs with mock blocks until the robot server is up.

## How it plays

The liquid fills the chamber. On the real table, the operator moves **one block** along a path on the printed **3 × 4 grid sheet**. Each time the block lands on the next square of the path, a giant block (a cube with a ledge) drops onto the tower in Roblox, and the ledges spiral up. Nothing stacks in real life; the stacking only happens in the game. The player climbs the ledges to stay above the liquid.

- **The path:** each round picks a new one. It only uses straight moves to a neighbouring square (no diagonals, no jumps), snaking along the rows or the columns from a random corner. The Roblox player sees it as a map in the **top-right of the screen**: numbered stops, done squares in green, and the next square pulsing yellow. The subtitle reads "Move the block to B3 (2/6)".
- **Difficulty** (the `Difficulty` attribute on `ServerStorage.Modes.Flood`: `Easy`, `Medium`, `Hard` or `Random`, default **`Random`**). With `Random`, the **next** round's difficulty is rolled while players are still in the lobby (never the same twice in a row) and shown on the Rising Flood bay's floor label, e.g. `HARD · 12 SQUARES · 90s`. It re-rolls after every round. The countdown subtitle repeats it ("HARD: 12 squares. Get ready to climb!").

  | Difficulty | Squares | Round time | Step height |
  |---|---|---|---|
  | Easy | 6 | 60 s | 5 studs |
  | Medium | 9 | 75 s | 5 studs |
  | Hard | 12 (whole grid) | 90 s | 4 studs (so a 12-block tower fits under the ceiling) |

- **Spawn:** players start right next to the tower spot, on the diagonals between the four ledge directions (so new ledges never spawn inside them), facing the tower. `ArenaSpawn` is no longer used for placement.
- **Countdown:** 3 s. A shallow puddle appears on the floor.
- **Grace period:** 5 s, then the liquid starts rising.
- **The liquid** rises steadily toward a level just below the waist of anyone on the second-to-last ledge. With `RISE_SPEED = 0.8` it only gets 80% of the way there by 0:00, so finishing the path (instant escape) is the main way to win, but a mostly-built tower can also outlast the timer.
- **Flooded:** when the liquid reaches a player's waist, they're out. They're slowed down and can't jump high, but they stay in the chamber.
- **New block landing on a player:** the player gets lifted on top of it, never trapped inside.

## Win condition (for scoring)

- **Escaped (early win):** the operator finishes the whole path → the round ends **immediately**, and everyone still above the liquid gets `{won = true}` ("YOU ESCAPED THE FLOOD!")
- **Won:** the player is still above the liquid when the round timer runs out → `{won = true}`
- **Lost:** flooded at any point, or left the game → `{won = false}`
- If everyone floods, the round ends immediately and nobody wins.
- Every surviving player gets a Win. The arm operator doesn't have a Roblox character, so they don't score.

## Robot input: the grid sheet

**Printables** (in `assets/markers/`, print at 100% scale with no margins, and check the 50.8 mm scale bar):
- `grid_sheet_3x4.print.html`: landscape Letter. 3 rows (**A–C**, row A on the arm's side) × 4 columns (**1–4**), 57.15 mm cells, grid origin at (25.40, 22.225) mm from the sheet's top-left corner.
- `mat_tags.print.html`: ArUco tags 0–3. Tape them so each tag's marked inner corner touches its corner of the sheet (0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left). Their inner corners give the homography from camera to sheet.

**What Python sends:** the normal state message with the block in `blocks`. Either form works, and nothing else is needed (no tower count, no stacking):

```json
{"t":"state", "blocks":[{"id":11, "cell":"B3", "visible":true}]}
{"t":"state", "blocks":[{"id":11, "x":16.83, "y":10.80, "visible":true}]}
```

- `cell`: the square the block is in, as written on the sheet (`"A1"`–`"C4"`). This is the preferred form.
- `x` / `y`: centimetres from the sheet's top-left corner (tag 0's inner corner), x across, y down the sheet toward row C. Roblox works out the square itself.
- Blocks that are `held` (in the gripper) or `visible:false` are ignored, so the move only counts once the block is put down.
- Roblox ignores any square that isn't the next one on the path, so wandering, going back, or a jittery reading on the current square never adds blocks.

Roblox builds the path itself and publishes it on `ReplicatedStorage.Flood` as the attributes `Path` (e.g. `"A1,A2,A3,A4,B4,B3"`) and `Progress`, in case the Python debug view wants to draw it.

## The chamber

A sealed industrial room (64 × 64 studs, 66 high) at x = 400, floor top at y = 20. It lives in `ServerStorage.Modes.Flood.Map` and is cloned into Workspace only while a round runs:

- Metal walls with steel ribs, a ceiling, and a yellow and black hazard border on the floor
- Cyan **LEVEL 1–8** depth lines at each ledge height, plus a gold **SAFE LINE 5**
- A **BLOCK DROP ZONE** pedestal in the middle, where the tower grows; a see-through ghost shows where the next block will land
- A ceiling gantry with a spotlight on the tower (where the Sky Arm can hang)
- Four wall pipes that pour water and red alarm lights that pulse while the water rises
- A "RISING FLOOD" sign on the back wall

## Tuning (`ReplicatedStorage.Flood.FloodConfig`)

| Setting | Value | What it does |
|---|---|---|
| `DIFFICULTY` | Easy 6 / 60 s, Medium 9 / 75 s, Hard 12 / 90 s | Path length (squares) and round time per difficulty |
| `RISE_SPEED` | 0.8 | How fast the liquid rises. 1 = reaches its top level exactly at 0:00; lower is slower |
| `GRACE_TIME` | 5 | Seconds before the liquid starts rising. Raise it if the real arm is slow to make the first move |
| `COUNTDOWN` | 3 | Countdown before the round |
| `STEP_HEIGHT` | 5 | Studs per block. Must stay under the jump height (7.2) |
| `MAX_TOWER_HEIGHT` | 48 | Long paths use shorter steps so the top ledge fits under the ceiling |
| `WAIST_HEIGHT` | 4.8 | Where players flood (scaled characters); sets the final liquid level each round |
| `GRID` | 57.15 mm cells, origin (25.4, 22.225) mm | Must match the printed grid sheet |
| `WATER_START` | 0.3 | Puddle depth at the start of the round |

The Water chamber's painted depth lines are moved and relabelled every round (by `Themes.Water.ThemeServer`), so **SAFE LINE** always marks the top ledge.

## Testing without the robot (Studio only)

| Key | Action |
|---|---|
| B | Pretend the block reached the next square (adds a block) |
| N | Step back one square (removes the top block) |
| C | Clear the tower |

The keys only work while you're inside the chamber during a round. Start a round by walking into the RISING FLOOD cabinet.

## Themes

Set the `Theme` attribute on `ServerStorage.Modes.Flood` to **Water**, **Sewer** (current setting), or **Random** (picks any map in `Themes`). The game logic, including the grid path, is the same for every theme.

- **Water:** the steel test chamber (`Themes.Water`)
- **Sewer:** a cartoony brick sewer flooding with green sludge (`Themes.Sewer`, 851 parts). Rusty pipes pour slime, rubber ducks/tire/Bloxy Cola cans float, lanterns flicker, a green countdown timer, and a second yellow arm comes down through the manhole holding a crate. Blocks drop in as wooden crates. **Twist:** sludge is sticky. With your feet in it you walk at 8 and jump 70% as high; reaching your waist still means flooded.
- **Tuning:** `Themes.Sewer.Settings` attributes (sticky speed, tint/blur, lighting values, junk bob, sound IDs, banner text)
- **Adding a theme (e.g. Lava):** copy a theme map, keep the anchor parts (`Floor`, `Water`, `WaterSurface`, `Tower`, `ArenaSpawn`), set the map's `Theme` attribute, and optionally add a `ThemeServer` hooks module plus a client module in `ReplicatedStorage.Flood.Themes`

## Where the code lives

| In Studio | Copy in the repo |
|---|---|
| `ServerStorage.Modes.Flood.Module` (ModuleScript) | `roblox/modes/Flood/Module.luau` |
| `ServerStorage.Modes.Flood.Themes.Water` / `.Sewer` (theme maps) | — (only in the place file) |
| `ServerStorage.Modes.Flood.Themes.Sewer.ThemeServer` (ModuleScript) | `roblox/modes/Flood/Themes/Sewer/ThemeServer.luau` |
| `ServerStorage.Modes.Flood.Themes.Water.ThemeServer` (ModuleScript) | `roblox/modes/Flood/Themes/Water/ThemeServer.luau` |
| `ReplicatedStorage.Flood.Themes.Sewer` (ModuleScript, client visuals) | `roblox/flood/themes/Sewer.luau` |
| `StarterPlayer.StarterPlayerScripts.FloodClient` (LocalScript) | `roblox/flood/FloodClient.client.luau` |
| `ReplicatedStorage.Flood.FloodConfig` (ModuleScript) | `roblox/flood/FloodConfig.luau` |
| `ReplicatedStorage.Flood` (remotes `FloodDebug`, `FloodFx`) | — |

Studio is the source of truth. If you change a script there, update the copy in the repo.

## Porting Flood to the contract

Done in step 4:

- [x] Moved the chamber into `ServerStorage.Modes.Flood.Map`; `Start` clones it into Workspace, `Stop` destroys it
- [x] Turned the standalone `FloodGame` script into `ServerStorage.Modes.Flood.Module` with `Start(players)`, `Stop()` and `Finished`. Every connection and thread is tracked and cleaned up in `Stop`
- [x] `Start` moves players to the chamber spawn and starts the countdown right away. The green start pad is gone; the arcade portal replaces it
- [x] Removed teleport-on-spawn; players spawn in the arcade
- [x] The round ends with a 4-second win/lose screen, then `Finished:Fire(results)`, with `won = true` for everyone still above water at 0:00, or as soon as the path is finished
- [x] Robot input comes from `StateStore.tower` instead of a BindableEvent
- [x] The Flood HUD only shows for players inside the chamber during a round
- [x] Flood's indoor lighting values are now the place-wide baseline, shared with the arcade
