# The debug menu — scenarios, fresh state, and playing without player 2

**Status:** built and verified.
**Code:** `lebot_obby/ServerScriptService/{DebugMenu,RunControl}.lua`,
`lebot_obby/StarterPlayerScripts/DebugMenu.client.lua`
**Toggle:** `Config.DebugMode`

---

## 1. What it does

A panel in the top-left (F1 hides it) listing all nine bays by obstacle name. Click one to jump
to it; **START RUN HERE** begins a clean run on it. Underneath, one button decides whether a
second player exists at all.

| Control | Does |
|---|---|
| Bay 1–9 | Jump to that scenario. The active bay follows, so the mat maps to it |
| **START RUN HERE** | Rebuild the obstacle, wipe its crates, heal, place you outside the door |
| RESET THIS BAY | Same rebuild, without moving you |
| RESET ALL BAYS | All nine, from scratch |
| **P2** | Cycle the crate source: LIVE ARM → SIMULATED → NOBODY |

The panel renders only what the server pushes it (`DebugStatus`), so it cannot drift from what
the game believes. A bay that is solved shows green.

## 2. Why "start a run" puts you *outside* the bay

A run starts on the catwalk, four studs before the entrance, not inside the bay. That is
deliberate: teleporting *into* a bay skips the doorway, and skipping the doorway is exactly how
bay 1's entry-blocking wall survived testing — the test teleported to row 2 and never walked
through the door ([bay-01-saw-wall.md](bay-01-saw-wall.md), bug 1). Starting outside means the
entry path is exercised every single time.

It also reloads the character rather than setting `Health = MaxHealth`, because that does not
revive a *destroyed* Humanoid, and a stale character reads as "nobody in the bay" — so the
obstacle never arms and the test passes without testing anything (same doc, bug 2).

## 3. Fresh state means rebuilt, not tidied up

The old R-hotkey reset called `setSolved(false)` plus an optional per-obstacle `state.reset()`,
and carried a standing caveat: obstacles presenting "solved" as a one-shot tween (the laser
grid fading out) never animated back, so their loops resumed while the visual stayed cleared.
Only the saw bay rebuilt properly.

A bay is now reset by **rebuilding it**. `buildBay` already destroyed the `Obstacle` folder and
re-ran the builder, and every run loop in `HazardManager` is `while folder.Parent do` — so
destroying the folder terminates all of them cleanly. Rebuilding is therefore a genuine fresh
state for every bay, and the caveat is gone rather than documented.

Crates are a separate concern and belong to `BlockSync.clearBay`. A rebuilt bay that kept the
previous run's crates would also keep the diff state saying they are there, so re-placing the
same cube would be a silent no-op and the bay would look broken.

## 4. The three second-player modes

Exactly one source may own the crates, and **which one is a runtime choice**, not a startup
constant — the point is to flip it mid-session rather than restart the place to change a
boolean. `RunControl` owns it.

| Mode | Crates come from | Use it to |
|---|---|---|
| `live` | the real arm (or `tools/mock_bridge.py`) over the WebSocket | play for real |
| `sim` | the on-screen 4×3 cell editor, standing in for player 2 | debug game logic solo |
| `none` | nothing — no crates at all | walk bays, test geometry, hazards and death solo |

The arm mirror keeps mirroring in every mode: seeing the real arm move is useful even while
debugging solo, and it costs nothing. Only the crates are gated.

Switching modes clears the active bay's crates, because crates from the previous source belong
to the previous source. Verified by size — a `sim` crate is the 4-stud model, a live cube is
6.72 studs and carries `IsCrate`.

`live` dials the socket lazily, on first entry into that mode. `Bridge` retries every 2 s with
a warning, so dialling a socket nobody is serving — the normal case when debugging solo — would
otherwise fill the output with noise.

## 5. One mat, nine bays

`RunControl.activeBay` is the single answer to "which bay does the mat map to", because three
things have to agree on it: both crate sources, and `Mapping`, whose `ORIGIN` is derived from
that bay's `Cell_0_0` anchor.

`DebugMode` used to pin `Bay01`. With the menu able to jump anywhere, that meant every scenario
after the first looked unsolvable — the clicks went to a bay nobody was standing in. Both
sources now follow `RunControl`, and crates are cleared out of the bay being left behind.

**This is the shape `ActiveBayTracker` should take.** When it arrives it calls
`RunControl.setActiveBay` from player 1's position and nothing else changes.

## 6. Verified

| Check | Result |
|---|---|
| Teleport to bay 5 | Z = 116, against a bay starting at Z = 120 |
| Teleport to bay 9 | Z = 236 |
| `startRun 3` | Z = 56, healed, bay 3 active |
| Status push | 9 bays named, active bay and feed mode correct |
| Cell editor targets the active bay | placed into **Bay 2** after jumping there (was pinned to Bay 1) |
| Solve then reset | `solved` true → **false**, **0 crates left**, obstacle folder rebuilt |
| `none` mode | clicking the grid produces **0** crates |
| `sim` mode | the same click produces **1** |
| `live` handover | 4-stud sim crate cleared; 6.72-stud live cube arrives |
| HUD layout | menu 0–358, ghost badge 428–454, cell grid 462–724; no overlap |
| Console | **0 errors or warnings** |

## 7. Not done

- **No run clock or scoring.** "Start a run" means a fresh bay, not a timed attempt — `GameState`
  still does not exist, so there is nothing to time or score.
- **No checkpoints.** Dying still respawns at world spawn; the menu is the way back.
- **Bay 1's levers still need a human.** `ProximityPrompt:InputHoldBegin()` is client-side, so
  the throw itself cannot be driven from a test.
- **The panel is player-1 shaped.** When the overseer client exists it will want its own view —
  which bay is live and what that bay wants — rather than this one.
