# Robo-Obby planning docs

Start here when picking the project up cold. This file is **the current state**; the master
plan is the original intent and has diverged.

| Doc | What it is |
|---|---|
| [obby_plan.md](obby_plan.md) | The master plan. Numbered sections (0–21) that the Luau comments cite — "Section 7", "Section 10.2" etc. refer to it. **§4.1–4.2 and §12 are superseded**, and so is every colour requirement in it. |
| [robot-link.md](robot-link.md) | The real arm into the game: the link, the mat→bay mapping, and the two-player shape. Built and verified against a mock. |
| [bay-04-dark-room.md](bay-04-dark-room.md) | Bay 4, built and solved end to end. |
| [debug-menu.md](debug-menu.md) | Jumping to any scenario, fresh state, and playing without a second player. |
| [bay-01-saw-wall.md](bay-01-saw-wall.md) | Bay 1, built and verified end to end. |
| [bay-02-void.md](bay-02-void.md) | Bay 2, built and verified end to end. |
| [bay-03-laser-walk.md](bay-03-laser-walk.md) | Bay 3, built and verified end to end. |
| [ui.md](ui.md) | The interface: the shared `UiTheme`, the three HUD layers, player 2's order card, and what happened to the floating labels. |
| [environment.md](environment.md) | The steampunk hall: the backdrop, containment, lighting, the overseer's column and the `build/` generators that produce it all. |

Every bay in scope has one. The parked bays (5–9) don't, and won't until `Config.NumBays`
is raised.

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
| `BayData` | `ReplicatedStorage/BayData.lua` | One obstacle per bay. 9 entries, the first 4 in scope |
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
| `BridgeFeed` | `ServerScriptService/BridgeFeed.lua` | The live feed wired into the bay |
| `RunControl` | `ServerScriptService/RunControl.lua` | Which bay is live and which source owns the crates |
| `ActiveBayTracker` | `ServerScriptService/ActiveBayTracker.lua` | The sliding window: the mat follows the runner |
| `DebugMenu` | `ServerScriptService/DebugMenu.lua` + client | Jump to any scenario, start a clean run, toggle player 2 |
| `OverseerCam` | `StarterPlayerScripts/OverseerCam.client.lua` | Player 2's view: **V** for a drivable top-down shot of the active bay, x-ray walls, labelled cells, a mini grid |

**Not built:** `GameState`/checkpoints, `Events` (malfunctions), scoring, win/fail screens,
Demo Run, and — on the overseer side — role assignment and a `CONTROLLER OFFLINE` banner. The
overseer *camera* exists; what's missing is deciding who is player 2 and telling them the link
has dropped.

`Bridge` is mirrored now, but bay 3 still reaches it through an optional
`pcall(require)` so a branch without the robot link plays unchanged. Keep it that way.

### Against the plan's build order (§10.2)

| Step | Status |
|---|---|
| 1 Bay prefab + `cellToWorld` | ✅ |
| 2 `DebugMode` cell editor + fake feed | ✅ |
| 3 `BlockSync` crate spawn, L1/L2 | ✅ |
| 4 One bay playable with clock + checkpoint | ❌ no checkpoints or run clock |
| 5 Crate effects and hazards | ✅ reinterpreted as one obstacle per bay |
| 6 Bays 1–9, `ActiveBayTracker`, camera | ⚠️ four bays in scope, tracker built, overseer camera built; bays 5–9 parked |
| 7 HUD, callouts, scoring, win/fail | ⚠️ objective HUD + timer only |
| 8 `SkyArm` on the mock feed | ✅ |
| 9 Real `Bridge` | ⚠️ link, arm mirror and crates-from-real-cubes all verified against a protocol-faithful mock; nothing run against real hardware — see [robot-link.md](robot-link.md) |
| 10 `Events` / malfunctions | ❌ |
| 11 Purple crane + Bay 9 finale | ❌ |
| 12 Demo Run, audio, polish | ❌ |

---

## Bay status

Bay 1 was rebuilt around **one obstacle per 4×3 bay**, with the crates as a *ladder to the
answer* rather than the answer. Bay 2 is the counterpart: a pure **placement** bay where
filling the cells *is* the solve, and where the crates are the floor. Bay 3 is the third
shape — **one** crate, moved repeatedly, where the cell it sits in is the only safe ground
and the route is randomised per run. Bay 4 is the fourth — a **search**, where a block is a
lantern rather than footing. Bays 5–9 are still the older sketch of that model and have not had
a design pass; they are also out of scope (see below), so they are parked rather than pending.

No bay requires a colour any more — **any block satisfies any cell** — so the old Colour
column has been replaced by what a bay actually costs in cubes.

**Scope: four bays.** `Config.NumBays = 4`. The rest are parked — their `BayData` entries sit
past that index so nothing builds them, and their geometry is in `ServerStorage.OutOfScope`.
Raise `NumBays` and re-run `build/scope_course.lua` to bring them back; nothing was deleted.

DarkZone moved from bay 8 to bay 4, because the course has to be contiguous — left at 8 you
would walk through four empty bays to reach it.

| # | Obstacle | Cubes | Solve | Redesigned |
|---|---|---|---|---|
| 1 | **Saw Wall** | 3 (1 + a stack of 2) | **two levers, exact stand level, hold E** | ✅ built & verified; 16-stud unvaultable wall, 75 s |
| 2 | **Void** | 2 | cells (1,0) (1,1) | ✅ built & verified |
| 3 | **Laser Walk** | **1**, moved repeatedly | **walk it along a random 6–8 cell route** | ✅ built & verified |
| 4 | **Dark Room** | any, moved to sweep light | **find 10 screws, then drive the power box** | ✅ built & verified |

**Parked (out of scope):** Lava `[5]`, Crusher roof `[6]`, Mobs `[7]`, Arrow turrets `[8]`,
Ice `[9]`.

---

## Rules that apply to every bay

**Two modes, one contract.** `solo` is one player doing both jobs — you place on the 4×3 grid
and the Sky Arm carries it in. `live` is the real SO-101, where only your hands place a block.
Nothing scripted, ever. `BlockSync.applyCells` and `BlockSync.applyBlocks` both end at
`CellsChanged` and both fire `CratePlaced` when a crate actually seats, so a bay never cares
which is driving it. Switching modes rebuilds every bay and clears every crate — see
[debug-menu.md](debug-menu.md).

**Blocks are interchangeable.** No obstacle requires a particular colour — the operator places
whichever cube is to hand, and any block satisfies any cell. Crates still *spawn* in their
colours, and the debug editor still picks one, but that is appearance: there is no colour test
anywhere in the solve path. **Don't add one.**

**Cube budget.** `level` is still enforced, because it is a cube *count*: level 1 is one cube
in the cell, level 2 is two stacked. **Three-high stacks do not exist.** The rig owns 14 cubes
in total, and every bay is designed around 1 or 2 — a ceiling inherited from when the limit was
two cubes *per colour*, and now self-imposed rather than physical.

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

1. **Placement** (the default, and **bay 2** is the only bay in scope that uses it) —
   `checkSolved` watches `BlockSync.CellsChanged` and marks the bay solved when every
   `solveCell` holds a crate at or above the required level. Colour is not checked. The parked
   bays 5–9 are all written as placement bays.
2. **Action** (`solveMode = "switches"` in bay 1, `"action"` in bays 3 and 4) — the obstacle owns
   `state.solved` and sets it itself; `ownsItsSolve(info)` makes `checkSolved` skip the bay,
   and `solveCells` degrades to a hint or can be omitted entirely. Use this whenever the
   crates are the *means* rather than the goal, or when the cells are decided at runtime.

An action bay should set its own `info.banner`; the default describes a placement bay via
`blockReq(level)` (`SAW  -  BLOCK`, `CRUSHERROOF  -  STACK x2`), and switch-mode bays used to
inherit bay 1's `THROW BOTH LEVERS`.

Both go through one `state.setSolved`, which owns the label and the edge-triggered `onSolved`.
A switch-mode bay **cannot be un-solved by clearing cells** — the R hotkey resets every bay.

**Objective HUD.** Build a payload of
`{title, task, hint, tone, timer, timerLabel, timerTone, flash}` and hand it to
`publishObjective(bayIndex, payload, pad)`; `nil` clears. Nothing in it is saw-wall specific.

⚠️ **Never `FireAllClients` on this remote.** It is one channel shared by every bay, so a
broadcast clear from an empty bay wipes the callout of the bay the player is standing in —
which is exactly what bay 1 did to bay 2 until arbitration went in. `publishObjective`
addresses only the players inside that bay, and retracts only what that bay put up. `pad`
widens the catchment toward the entrance so a bay can brief the player on the approach.

**A refusal is visible.** `BlockSync.PlacementRejected` is picked up centrally in
`HazardManager` and merged into the next objective push as a `flash`, so any bay that turns a
block away says so on screen. A bay may still set its own `flash` and it wins. Before this,
only the saw wall announced refusals — bay 3 silently rejecting a block that was not the next
cell on its route looked exactly like the block never arriving.

**A cube can be a token instead of an object.** A bay that sets `VirtualCrates` on its model
gets no crate part at all — the cell bookkeeping still happens, so `CellsChanged`, `CratePlaced`
and solve detection are unchanged, but nothing is carried in and nothing is left standing. The
laser walk uses it: the operator slides a real cube across the real mat and the matching tile
goes quiet, while the player walks on the floor. A crate there was scenery that read as "climb
me" in the one bay where climbing is not the point.

**Crates can sit flush.** A bay whose crates *are* the floor sets `CrateSink` on its model and
`cellToWorld` drops them by that much. The void uses one cube, so its bridge is level with the
walkway instead of standing a cube proud of it.

**Placement guards.** `BlockSync.setPlacementGuard(bayModel, fn)` lets an obstacle refuse a
delivery into its own bay. A refusal is **parked, not discarded** — the operator's cube is
still on the real table — and `BlockSync.retryRejected(bayModel)` re-offers it when the guard
changes its mind.

**`CellsChanged` is the snapshot, not the arrival.** It fires the moment the operator's cube
moves on the real table — before the arm has carried anything, and whether or not a guard
ends up refusing it. If a bay's *timing or safety* depends on the crate actually being there,
listen to **`BlockSync.CratePlaced(bayModel, cell)`**, which fires from the delivery's
`onArrive`. Bay 3 marked a refused cell safe to stand on until this existed.

**One bay owns the HUD at a time.** `pad` windows of neighbouring bays overlap (the gap is
6 studs, a pad is usually a whole 8-stud cell), so `hudBayFor(pos, pad)` picks a single owner:
containment wins, and outside every bay body the bay you're walking *towards* beats the one
you just left. `publishObjective` already uses it — don't re-derive ownership per bay.

**Presentation must not hang off `state.solved`.** `buildBay`'s `setSolved` only calls
`onSolved` on the way *in*, so anything driven from it stays stuck on "cleared" when the bay
is later un-solved. Drive visuals from what has actually landed instead (bay 2's `refresh()`).

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

- ~~`ActiveBayTracker` doesn't exist.~~ **Built.** The mat follows the runner: walk out of a
  bay and the window moves with you, taking the crane, `Mapping`'s origin, the cell editor and
  crate delivery with it. The catwalk counts as the bay *ahead*, so the operator is placing
  while you approach rather than catching up once you are inside.
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
  2 is the overseer whose only input is the real arm. ~~The overseer client doesn't exist yet.~~
  **Camera built** (`OverseerCam`, **V**) — see [debug-menu.md](debug-menu.md) §4b. Still open:
  nothing *assigns* the roles, so in solo one person flips between both views, and a dropped
  link is only visible in the console.
- ~~The mat sweep un-solves placement bays.~~ **Fixed.** Solved placement bays now latch;
  reproduced and re-verified on Bay 2 (see [robot-link.md](robot-link.md) §5).
- ~~Reset is partial.~~ **Fixed.** A bay is reset by rebuilding it, which terminates every run
  loop (`while folder.Parent do`) and re-runs the builder, so every bay comes back genuinely
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
- **Don't hardcode a randomised route into a test.** A bay-3 test that assumed step 1 was
  `(3,0)` "passed" against a run whose step 1 was elsewhere, and masked a real safety bug.
  Read the expected target off the HUD payload.
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
