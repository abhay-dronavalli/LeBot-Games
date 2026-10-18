# The debug menu — scenarios, fresh state, and playing without player 2

**Status:** built and verified.
**Code:** `lebot_obby/ServerScriptService/{DebugMenu,RunControl}.lua`,
`lebot_obby/StarterPlayerScripts/DebugMenu.client.lua`
**Toggle:** `Config.DebugMode`

---

## 1. What it does

A panel in the top-left (F1 hides it) listing every bay in scope by obstacle name. Click one
to jump to it; **START RUN HERE** begins a clean run on it. Underneath, one button decides
whether a second player exists at all.

The list is built from `Config.NumBays`, so it is **four** entries today — Saw, Void,
LaserWalk, DarkZone. Every bay index is clamped to that, so there is no way to jump to a parked
bay: raise `NumBays` and the menu grows by itself.

| Control | Does |
|---|---|
| Bay 1–`NumBays` | Jump to that scenario. The active bay follows, so the mat maps to it |
| **START RUN HERE** | Rebuild the obstacle, wipe its crates, heal, place you outside the door |
| RESET THIS BAY | Same rebuild, without moving you |
| RESET ALL BAYS | Every bay in scope, from scratch |
| **P2** | Cycle the crate source: LIVE ARM → SIMULATED → NOBODY |
| **F1** | Hide / show the panel |
| **F2** | **RESET EVERYTHING** — every bay rebuilt and you back on the spawn. Bound to a key rather than only a button because it has to be reachable with the panel hidden, which is how you would actually be playing |
| **R** | Rebuild every bay, leaving you where you are (handled in `HazardManager`, not the menu) |

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

## 4. Two modes

Exactly one source owns the crates, and **which one is a runtime choice**, not a startup
constant — the point is to flip it mid-session rather than restart the place to change a
boolean. `RunControl` owns it. `Config.FeedMode` sets the boot mode; it is `solo`.

| Mode | Who places a block | The arm is driven by |
|---|---|---|
| **`solo`** | you, on the on-screen 4×3 grid — one player doing both jobs | the delivery job queue, carrying what you placed |
| **`live`** | your hands on the real SO-101, and nothing else | the real arm's tip, over the socket |

There is deliberately **no scripted or recorded third mode**. A feed that places blocks by
itself is indistinguishable from the game doing it on its own, which is alarming — and was,
until `tools/mock_bridge.py --bay 1` was traced as the culprit. That tool still exists for
testing the link without hardware, but it is not part of either mode.

**Switching resets the world.** Every bay is rebuilt and every crate cleared. The two modes
disagree about who owns the crates and about what is driving the arm, so nothing may survive
the switch: crates placed by the other source are not yours, and a half-built bay from the
previous mode is just confusing.

Leaving `live` also **hangs up**. `Bridge.disconnect()` stops the retry loop — otherwise a link
dialled once keeps reconnecting to a socket nobody is serving every 2 s for the rest of the
session, flapping `CONTROLLER ONLINE`/`OFFLINE` and burying a real connection failure in noise.

Two things have to be forgotten on a reset, and both caused bugs:

- **`SkyArm.setLiveMode`** follows the mode. Left on in solo, the Heartbeat kept lerping the
  trolley toward a stale live target while a queued delivery tweened it somewhere else.
- **`DebugMode`'s per-bay cell state** is cleared via `RunControl.BayReset`. `clearBay` wipes
  the diff baseline, so a cell the editor still believed in was re-delivered on the very next
  edit — one click after a reset produced two crates, one of them from the previous run.

## 4b. The overseer view (**V**)

Player 2's view. **V** toggles between the runner's over-the-shoulder camera and an elevated
shot of the active bay, so in solo one person can flip between the two halves of the game and
check what the operator is looking at.

| Control | Does |
|---|---|
| **V** | Toggle the overseer view on / off |
| **G** | Toggle the x-ray walls (also a button on the panel) |
| **−** / **=** / mouse wheel | Zoom out / in |
| **Right-drag** | Pan across the bay. Right rather than left, and with no `gameProcessed` guard, because the drag starts over the middle of the screen where the objective panel and the mini grid both live |
| RECENTER VIEW | Back to the default zoom and centre. Switching bays also resets the framing |

Every binding is `ContextActionService:BindActionAtPriority` and **passes rather than sinks
while the view is off**, so none of these keys is stolen from the runner — **G** is none of
this script's business until the overseer view is actually up.

The angle is elevated, from the entrance end, looking down the bay. That is not arbitrary:

- Columns (X) spread left-to-right and rows (Z) recede, which is exactly how the printed mat
  and the 4×3 debug grid are laid out. A side-on view would foreshorten the columns and turn
  "col 2, row 1" into guesswork.
- It is where the Sky Arm stands, so what the overseer sees and what the arm reaches share a
  mental model.
- y = 38 clears a bay's own furniture — bay 1's 16-stud saw wall and side walls — while
  staying under the roof trusses at 46.

Every cell is labelled with its `col,row` painted flat on the floor, and the cells this bay
wants a block in are **green** (`solveCells`, carried in the status payload). A called-out
"(1,0)" is then somewhere you can see rather than count out.

**The runner is outlined**, with a `Highlight` set to `AlwaysOnTop`, so they are findable in
a dark room or behind an obstacle rather than being a shape you have to hunt for.

**A mini 4×3 grid** sits on the right, laid out the same way round as the printed mat and the
debug grid — far row at the top, col 0 on the right — so what is on screen and what the
operator reaches for line up without translating. Green is a cell the bay wants, blue is a cell
holding a block, amber rings the cell the runner is standing in. The occupied state comes from
a `BayCells` remote rather than from looking at the world, because bays 3 and 4 set
`VirtualCrates` and have no crate to see.

**Walls go transparent client-side.** The warehouse shell sits between this camera and the
bay, so three layers are raised while the view is on: the warehouse shell, the **roof trusses** at
y = 46, and the **active bay's own walls and ceiling**. Bay 4 is the acute case — the dark room
is roofed at y = 14, so without it the overseer is looking at the top of a closed box; the
trusses laid two black bars across the bay once the camera went above them. Doing it on
the client matters: it is this viewer's x-ray, not a change to the world, so player 1 still
sees solid walls around them. It is restored on the way out, along with the camera subject and
the markers.

Two things that cost time here: a `BillboardGui` adorned to the marker **did not render at
all** — correct text, laid-out `AbsoluteSize`, nothing on screen — so the labels are a
`SurfaceGui` on the pad's top face instead, which also reads better from above. And a Top-face
`SurfaceGui`'s own axes run across the bay, so the text needs `Rotation = -90` to face the
camera; `+90` renders it upside down, which at a glance looks merely mirrored.

## 5. One mat, every bay

`RunControl.activeBay` is the single answer to "which bay does the mat map to", because three
things have to agree on it: both crate sources, and `Mapping`, whose `ORIGIN` is derived from
that bay's `Cell_0_0` anchor.

`DebugMode` used to pin `Bay01`. With the menu able to jump anywhere, that meant every scenario
after the first looked unsolvable — the clicks went to a bay nobody was standing in. Both
sources now follow `RunControl`, and crates are cleared out of the bay being left behind.

**This was the shape `ActiveBayTracker` should take, and it is the shape it took.** It is
built: it calls `RunControl.setActiveBay` from the runner's position and nothing else changed.
The one rule worth knowing is that **the catwalk counts as the bay ahead**, so the mat is ready
before you walk in rather than a moment after — which also keeps it agreeing with this menu,
whose "start run" drops you on that approach catwalk.

## 6. Verified

Measured when all nine bays were in scope. The bay-5 and bay-9 jumps are no longer reachable
— every index is clamped to `Config.NumBays` — but they are kept because what they prove is the
arithmetic (`zStart - 4` on the approach catwalk), which did not change.

| Check | Result |
|---|---|
| Teleport to bay 5 | Z = 116, against a bay starting at Z = 120 *(out of scope now)* |
| Teleport to bay 9 | Z = 236 *(out of scope now)* |
| `startRun 3` | Z = 56, healed, bay 3 active |
| Status push | bays named, active bay and feed mode correct (9 then, 4 now) |
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
- **The panel is player-1 shaped.** The overseer has a camera (§4b) but not a panel: what they
  want is which bay is live and what that bay wants, not a list of bays to teleport into.
- **Nothing assigns the roles.** `P2` decides whether a second crate source exists, not who is
  player 2. In solo one person flips between both views with **V**.
