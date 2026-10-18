# Robo-Obby planning docs

Start here when picking the project up cold. This file is **the current state**; the master
plan is the original intent and has diverged.

| Doc | What it is |
|---|---|
| [obby_plan.md](obby_plan.md) | The master plan. Numbered sections (0–21) that the Luau comments cite — "Section 7", "Section 10.2" etc. refer to it. **§4.1–4.2 and §12 are superseded.** |
| [robot-link.md](robot-link.md) | The real arm into the game: the link, the mat→bay mapping, and the two-player shape. Built and verified against a mock. |
| [debug-menu.md](debug-menu.md) | Jumping to any scenario, fresh state, and playing without a second player. |
| [bay-01-saw-wall.md](bay-01-saw-wall.md) | Bay 1, built and verified end to end. |

One doc per scenario lands here as each bay is designed. Bays 2–9 don't have one yet.

> **Correction.** This file and `obby_plan.md` both used to say Part III and the §12 protocol
> were "still accurate and untouched". **§12 is superseded** by the `robot-roblox-bridge`
> branch's `PROTOCOL.md` v1, which is structurally different: the arm arrives as a stick figure
> of world points rather than joint angles, `blocks` replaces `cells` (no `col`/`row` on the
> wire), `held` replaces `crane`, there is **no ArUco on the cubes**, and the effect names
> differ (`fog`, not `steam_lag`). See [robot-link.md](robot-link.md).

---

## Where the code lives

The Roblox place is a binary `.rbxl` and is gitignored, so every Luau script is mirrored as
text under [`lebot_obby/`](../lebot_obby/) — see its README for the repo-path → Studio-location
map, and for what git *cannot* see (the warehouse geometry is baked into the place file only).

---

## What exists right now

| System | Where | State |
|---|---|---|
| `Config` | `ReplicatedStorage/Config.lua` | All tunables, single source of truth |
| `CrateDefs` | `ReplicatedStorage/CrateDefs.lua` | 7 colour-coded crates + L1/L2 effect names |
| `BayData` | `ReplicatedStorage/BayData.lua` | One obstacle per bay, 9 bays |
| `BlockSync` | `ServerScriptService/BlockSync.lua` | Cell→world, snapshot diffing, crate delivery, **placement guards** |
| `SkyArm` | `ServerScriptService/SkyArm.lua` | SO-101-proportioned rig, FK + IK, gantry travel, serialized job queue |
| `HazardManager` | `ServerScriptService/HazardManager.lua` | All 9 obstacle builders, solve detection, bay reset |
| `DebugMode` | `ServerScriptService/DebugMode.lua` | Stands in for the robot feed; same `cells` structure |
| `GhostMode` | `ServerScriptService/GhostMode.lua` | Q = fly + invincible, for touring bays |
| `ObjectiveHud` | `StarterPlayerScripts/ObjectiveHud.client.lua` | On-screen task + live countdown |
| `DebugCellEditor` | `StarterPlayerScripts/DebugCellEditor.client.lua` | 4×3 click grid, laid out as a map of the bay |
| `GhostControl` | `StarterPlayerScripts/GhostControl.client.lua` | Camera-relative ghost flight |
| `Bridge` | `ServerScriptService/Bridge.lua` | The WebSocket link to the robot. Verbatim from the bridge branch |
| `Mapping` | `ReplicatedStorage/Mapping.lua` | Sheet mm → studs. The scale is **pinned** by the cell size, not chosen |
| `ArmMirror` | `ServerScriptService/ArmMirror.lua` | Literal stick-figure mirror. Off by default — see `Config.ArmStyle` |
| `SkyArm` | `ServerScriptService/SkyArm.lua` | The gantry crane. Drives crate delivery in sim mode, and follows the real arm's tip in live mode |
| `BridgeFeed` | `ServerScriptService/BridgeFeed.lua` | The live feed wired into the bay |
| `RunControl` | `ServerScriptService/RunControl.lua` | Which bay is live and which source owns the crates |
| `DebugMenu` | `ServerScriptService/DebugMenu.lua` + client | Jump to any scenario, start a clean run, toggle player 2 |

**Not built:** `ActiveBayTracker`, `GameState`/checkpoints, `Events` (malfunctions), scoring,
win/fail screens, Demo Run, the overseer client.

### Against the plan's build order (§10.2)

| Step | Status |
|---|---|
| 1 Bay prefab + `cellToWorld` | ✅ |
| 2 `DebugMode` cell editor + fake feed | ✅ |
| 3 `BlockSync` crate spawn, L1/L2 | ✅ |
| 4 One bay playable with clock + checkpoint | ❌ no checkpoints or run clock |
| 5 Crate effects and hazards | ✅ reinterpreted as one obstacle per bay |
| 6 Bays 1–9, `ActiveBayTracker`, camera | ⚠️ bays exist; **no tracker, so only Bay 1 is wired** |
| 7 HUD, callouts, scoring, win/fail | ⚠️ objective HUD + timer only |
| 8 `SkyArm` on the mock feed | ✅ |
| 9 Real `Bridge` | ⚠️ link, arm mirror and crates-from-real-cubes all verified against a protocol-faithful mock; nothing run against real hardware — see [robot-link.md](robot-link.md) |
| 10 `Events` / malfunctions | ❌ |
| 11 Purple crane + Bay 9 finale | ❌ |
| 12 Demo Run, audio, polish | ❌ |

---

## Bay status

Bay 1 was rebuilt around **one obstacle per 4×3 bay**, with the crates as a *ladder to the
answer* rather than the answer. Bays 2–9 still use the older model where filling the right
cells with the right colour *is* the solve, and have not had that redesign pass.

| # | Obstacle | Colour | Lvl | Solve | Redesigned |
|---|---|---|---|---|---|
| 1 | **Saw Wall** | orange + red | 1 + 2 | **two levers, exact stand level, hold E** | ✅ built & verified; 16-stud unvaultable wall, 75 s |
| 2 | Void | red | 1 | cells (1,0) (1,1) | ❌ |
| 3 | Laser grid | yellow | 1 | cell (1,1) | ❌ |
| 4 | Lava | blue | 1 | cells (1,0) (1,1) | ❌ |
| 5 | Crusher roof | green | 2 | cell (1,1) | ❌ |
| 6 | Mobs | purple | 1 | cells (0,1) (3,1) | ❌ |
| 7 | Arrow turrets | yellow | 1 | cells (1,1) (2,1) | ❌ |
| 8 | Dark zone | teal | 1 | cells (1,1) (2,1) | ❌ |
| 9 | Ice (finale) | red | 1 | cells (0,1) (3,1) | ❌ |

---

## Rules that apply to every bay

**Cube budget.** The physical rig has **two cubes per colour**. A cell holds one colour at
level 1 (1 cube) or level 2 (2 cubes) — never two colours in one cell. So a bay may ask for at
most 2 of a colour: one L2 cell, or two L1 cells, or one L1 cell. Anything more is unsolvable
on the real table. **Three-high stacks do not exist.**

**The arm is the ceiling crane.** `Config.ArmStyle = "gantry"` (the default): it hangs from the
rails, slides along the roof between bays, and the real arm drives it by the tip. Height is
scaled separately from the floor plan so it fits the room — which does **not** affect resting
cube heights, only a held cube and the arm. `"mirror"` swaps in the literal 1:1 stick figure,
which needs a taller shell.

**Cube size is not a choice.** A 48 mm cube maps to **6.72 studs** and a stacked pair to
13.44, against a default jump of ~12.8 — so one cube is climbable and a pair is not, for free.
Any bay that gates on height should lean on that rather than on a tuned constant.

**Safe footing.** The blocks that solve an obstacle are also the player's footing. Nothing
may kill the player while they're standing on the thing that solved it. *(Bay 1 is the one
deliberate exception — see its doc.)*

**Crates are indestructible.** The real cube is still on the operator's table and the game
must mirror it, so no obstacle may destroy a crate. Resolve contact some other way.

**One obstacle per bay.** Each 4×3 bay is a single obstacle, not one-block-one-trap.

---

## Shared systems a new bay can use

**Two ways a bay can be solved**

1. **Placement** (bays 2–9, the default) — `checkSolved` watches `BlockSync.CellsChanged` and
   marks the bay solved when every `solveCell` holds a crate of the right colour at or above
   the required level.
2. **Action** (`solveMode = "switches"`, bay 1) — the obstacle owns `state.solved` and sets it
   itself; `checkSolved` skips the bay and `solveCells` degrades to a "stack here" hint. Use
   this whenever the crates are the *means* rather than the goal.

Both go through one `state.setSolved`, which owns the label and the edge-triggered `onSolved`.
A switch-mode bay **cannot be un-solved by clearing cells** — the R hotkey resets every bay.

**Objective HUD.** Fire `Remotes.Objective` with
`{title, task, hint, tone, timer, timerLabel, timerTone, flash}` to drive the on-screen task
panel and countdown; fire `nil` to clear it. Nothing in it is saw-wall specific.

**Placement guards.** `BlockSync.setPlacementGuard(bayModel, fn)` lets an obstacle refuse a
delivery into its own bay. A refusal is **parked, not discarded** — the operator's cube is
still on the real table — and `BlockSync.retryRejected(bayModel)` re-offers it when the guard
changes its mind.

**Reach gating.** To require a crate of a given height, raycast down from the player and check
the supporting part is a crate — tagged `IsCrate`, or the legacy `Base`/`Topper` names. Don't
rely on mounting things out of reach: a default Roblox jump clears about **12.8 studs of head
height**. Bay 1 gates on an **exact stand level** rather than a minimum, so standing too high
fails like standing too low; that is what makes a control cost its own crates.

**Objective checklist.** The HUD payload takes `steps` (a list of lines, `[x]`/`[ ]`/`[-]` for
done/ready/locked) and `note` (a standing explanation) alongside the task line. The panel
resizes to fit, so a bay that sends neither looks exactly as it did before.

---

## Known gaps

- **`ActiveBayTracker` doesn't exist.** `RunControl.activeBay` is the stand-in and the debug
  menu drives it, so every bay is now reachable; what is missing is picking it automatically
  from player 1's position. `RunControl.setActiveBay` is the call it should make.
- **No `GameState` / checkpoints.** Dying respawns you at world spawn. The debug menu is the
  way back to a scenario.
- **No run clock, scoring or malfunctions** (plan §6, §9) — `Config` has placeholder values,
  nothing reads them.
- **Warehouse geometry isn't reproducible from source.** Generated by command-bar scripts that
  weren't kept; it exists only in the `.rbxl`. Editing layout values in `Config.lua` will
  **not** move the baked bays — *except* the shell, which `build/fit_shell.lua` now fits to
  `Config.WallHeight` (first piece of the generator extraction). The ceiling is 48 studs.
  `BayGap` is still 6 and only matters if `Config.ArmStyle` is switched to `"mirror"`.
- **Two-player support is now the design**, not an open question: player 1 runs the bay, player
  2 is the overseer whose only input is the real arm. The overseer client doesn't exist yet.
- ~~The mat sweep un-solves placement bays.~~ **Fixed.** Solved placement bays now latch;
  reproduced and re-verified on Bay 2 (see [robot-link.md](robot-link.md) §5).
- ~~Reset is partial.~~ **Fixed.** A bay is reset by rebuilding it, which terminates every run
  loop (`while folder.Parent do`) and re-runs the builder, so all nine come back genuinely
  fresh — see [debug-menu.md](debug-menu.md) §3.
- **Nothing is playtested with a real arm.** Every timing number is a placeholder for human
  fumbling time nobody has measured.

---

## Testing notes that cost time to learn

- `execute_luau`'s **Server datamodel is a separate Luau VM** with its own module cache.
  `require(BlockSync)` there returns a *different instance* than the running game, so it proves
  nothing. Drive tests through the real `CellEdit` / `DebugHotkey` remotes.
- **`task.spawn` loops die when the `execute_luau` call returns.** A "hold the player in the
  bay" loop silently stopped, the bay emptied and reset, and it looked exactly like the feature
  under test was broken. Anything that must persist has to run inside one call.
- **Teleporting a test character can skip the thing you're testing.** A walk-in path has to be
  exercised, or checked geometrically (raycast / `GetPartBoundsInBox`).
- **`Humanoid:MoveTo` from the server does nothing** for a player-controlled character.
- **`Health = MaxHealth` does not revive a destroyed Humanoid.** Use `pl:LoadCharacter()`.
- **`ProximityPrompt:InputHoldBegin()` is client-side.** From the server it does nothing.
- **A closure only sees locals declared above it.** A guard that read a local declared further
  down silently got a nil global and allowed everything through.
- Mirror edits back out of Studio and **verify with a checksum**; transcription drifts silently.
  `tools/studio_sync.py` removes the transcription step entirely — see
  [`lebot_obby/README.md`](../lebot_obby/README.md).
- **`HttpService.HttpEnabled` defaults to off** and nothing connects without it. The failure
  reads like a bad URL.
- **`CreateWebStreamClient` works** in Studio 0.743, so the WebSocket path is real and the HTTP
  polling fallback in plan §0 is not needed.
- **The robot's own mock needs the whole robot package** (numpy, opencv, lerobot) and only runs
  on the robot laptop. `tools/mock_bridge.py` speaks the same protocol with no dependencies
  beyond `websockets`, so the Roblox side can be developed and verified on its own machine.
