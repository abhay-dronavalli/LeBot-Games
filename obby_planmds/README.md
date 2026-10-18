# Robo-Obby planning docs

Start here when picking the project up cold. This file is **the current state**; the master
plan is the original intent and has diverged.

| Doc | What it is |
|---|---|
| [obby_plan.md](obby_plan.md) | The master plan. Numbered sections (0–21) that the Luau comments cite — "Section 7", "Section 10.2" etc. refer to it. **§4.1–4.2 are superseded**, and so is every colour requirement in it; Part III (robot/vision/protocol) is still accurate and untouched. |
| [bay-01-saw-wall.md](bay-01-saw-wall.md) | Bay 1, built and verified end to end. |
| [bay-02-void.md](bay-02-void.md) | Bay 2, built and verified end to end. |
| [bay-03-laser-walk.md](bay-03-laser-walk.md) | Bay 3, built and verified end to end. |

One doc per scenario lands here as each bay is designed. Bays 4–9 don't have one yet.

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

**Not built here:** `ActiveBayTracker`, `GameState`/checkpoints,
`Events` (malfunctions), scoring, win/fail screens, Demo Run.

`Bridge` (the real robot feed) exists in the place file but **not in the text mirror** — it
arrived on the robot branch. Bay 3 publishes to it optionally, so a branch without it still
plays. Anything that needs it must `pcall(require)` rather than assume it.

### Against the plan's build order (§10.2)

| Step | Status |
|---|---|
| 1 Bay prefab + `cellToWorld` | ✅ |
| 2 `DebugMode` cell editor + fake feed | ✅ |
| 3 `BlockSync` crate spawn, L1/L2 | ✅ |
| 4 One bay playable with clock + checkpoint | ❌ no checkpoints or run clock |
| 5 Crate effects and hazards | ✅ reinterpreted as one obstacle per bay |
| 6 Bays 1–9, `ActiveBayTracker`, camera | ⚠️ bays exist; no real tracker, but `DebugMode` now follows an active bay so any bay can be played |
| 7 HUD, callouts, scoring, win/fail | ⚠️ objective HUD + timer only |
| 8 `SkyArm` on the mock feed | ✅ |
| 9 Real `Bridge` | ❌ |
| 10 `Events` / malfunctions | ❌ |
| 11 Purple crane + Bay 9 finale | ❌ |
| 12 Demo Run, audio, polish | ❌ |

---

## Bay status

Bay 1 was rebuilt around **one obstacle per 4×3 bay**, with the crates as a *ladder to the
answer* rather than the answer. Bay 2 is the counterpart: a pure **placement** bay where
filling the cells *is* the solve, and where the crates are the floor. Bay 3 is the third
shape — **one** crate, moved repeatedly, where the cell it sits in is the only safe ground
and the route is randomised per run. Bays 4–9 are still the older sketch of that model and
have not had a design pass.

No bay requires a colour any more — **any block satisfies any cell** — so the old Colour
column has been replaced by what a bay actually costs in cubes.

| # | Obstacle | Cubes | Solve | Redesigned |
|---|---|---|---|---|
| 1 | **Saw Wall** | 3 (1 + a stack of 2) | **two levers, hold E** | ✅ built & verified |
| 2 | **Void** | 2 | cells (1,0) (1,1) | ✅ built & verified |
| 3 | **Laser Walk** | **1**, moved repeatedly | **walk it along a random 6–8 cell route** | ✅ built & verified |
| 4 | Lava | 2 | cells (1,0) (1,1) | ❌ |
| 5 | Crusher roof | 2 (one L2 cell) | cell (1,1) | ❌ |
| 6 | Mobs | 2 | cells (0,1) (3,1) | ❌ |
| 7 | Arrow turrets | 2 | cells (1,1) (2,1) | ❌ |
| 8 | Dark zone | 2 | cells (1,1) (2,1) | ❌ — **its mechanic was the teal glow; needs a rethink** |
| 9 | Ice (finale) | 2 | cells (0,1) (3,1) | ❌ |

---

## Rules that apply to every bay

**Blocks are interchangeable.** No obstacle requires a particular colour — the operator places
whichever cube is to hand, and any block satisfies any cell. Crates still *spawn* in their
colours, and the debug editor still picks one, but that is appearance: there is no colour test
anywhere in the solve path. **Don't add one.**

**Cube budget.** `level` is still enforced, because it is a cube *count*: level 1 is one cube
in the cell, level 2 is two stacked. **Three-high stacks do not exist.** The rig owns 14 cubes
in total, and every bay is designed around 1 or 2 — a ceiling inherited from when the limit was
two cubes *per colour*, and now self-imposed rather than physical.

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
   marks the bay solved when every `solveCell` holds a crate at or above the required level.
   Colour is not checked.
2. **Action** (`solveMode = "switches"` in bay 1, `"action"` in bay 3) — the obstacle owns
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
the supporting part is a crate `Base`/`Topper` above a threshold. Don't rely on mounting
things out of reach: a default Roblox jump clears about **12.8 studs of head height**.

---

## Known gaps

- **`ActiveBayTracker` doesn't exist.** `DebugMode` now carries a minimal stand-in — one active
  bay that the number keys and `N` move, with per-bay cell state — so any bay can be played.
  The real tracker (driven by where the player actually is, not by a hotkey) is still missing.
- **No `GameState` / checkpoints.** Dying respawns you at world spawn.
- **No run clock, scoring or malfunctions** (plan §6, §9) — `Config` has placeholder values,
  nothing reads them.
- **Warehouse geometry isn't reproducible from source.** Generated by command-bar scripts that
  weren't kept; it exists only in the `.rbxl`. Editing layout values in `Config.lua` will
  **not** move the baked bays.
- **Two-player support** undecided.
- **Reset is partial.** Obstacles that show "solved" as a one-shot tween don't animate back;
  their loops resume but the visual stays cleared. Only the saw bay rebuilds properly.
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
