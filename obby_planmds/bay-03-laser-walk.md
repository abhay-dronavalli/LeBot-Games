# Bay 3 — Laser Walk

**Status:** built and verified in Studio. Solvable end to end.
**Shared systems used:** objective HUD + arbitration, placement guards, `BlockSync.CratePlaced`
(new), `Bridge` outbound frames — see [README.md](README.md).
**Code:** `lebot_obby/ServerScriptService/HazardManager.lua` → `BUILDERS.LaserWalk`
**Data:** `lebot_obby/ReplicatedStorage/BayData.lua` → `[3]`
**Tuning:** `lebot_obby/ReplicatedStorage/Config.lua` → `Laser*`

> Replaces the old `BUILDERS.Laser` (a whole-volume beam lattice killed by one mirror crate),
> which shared nothing with this design and has been removed.

---

## 1. The scenario

Every cell of the 4×3 grid is lethal. There is exactly **one** crate — any colour, the bay does
not care — and whatever cell it sits in is the only safe ground in the bay. You cross by having the operator walk that one
crate ahead of you, cell by cell, along a route **only they can see**.

Three rules make it a puzzle rather than a chore:

| Rule | Why |
|---|---|
| A cell holding the crate is safe; nothing else ever is | the crate *is* the floor |
| Only the **next** cell of the route accepts the crate | stops the operator shortcutting straight down a column |
| The cell just vacated stays safe for `LaserCooldownSeconds` | that gap is your window to follow the crate |

The route is **generated per run**, so the operator cannot memorise it — which is what makes
their physical overlay load-bearing rather than decorative.

---

## 2. The cooldown starts when the crate *lands*

This is the single most important timing decision in the bay.

One arm move is a remove **plus** a place — roughly **11s of flight**. If the vacated cell
started counting down when the crate was *lifted*, the cooldown would be spent before the crate
had arrived anywhere, and the bay would be a race against the arm rather than a race across the
floor.

So the countdown starts the moment the crate **seats** in its new cell:

```
crate lifted from (3,0)
   |
   |   arm in flight ~11s      (3,0) STILL SAFE
   v
crate seats at (2,0)           (2,0) -> SAFE
   |
   |   (3,0) cooldown: 6s      player walks (3,0) -> (2,0)
   v
(3,0) beams return
```

Measured in Studio: `5.7 → 3.8 → 1.8 → LIVE`, i.e. exactly the configured 6s.

**This is why `BlockSync.CratePlaced` had to exist** — see §5.1.

---

## 3. The route

A simple (non-repeating) orthogonal walk, `Config.LaserRouteMin`–`Max` cells long, starting on
a row-0 cell and finishing on a row-2 cell so the bay is genuinely crossed. Randomised DFS with
backtracking over the 12 cells — instant, and it always finds one.

A real generated route from a verified run:

```
entrance (z=60)
  row 0    .    .   [2]  [1]
  row 1    .    .   [3]  [4]
  row 2   [8]  [7]  [6]  [5]
exit (z=84)

(3,0) (2,0) (2,1) (3,1) (3,2) (2,2) (1,2) (0,2)
```

Right, forward, back, forward, then left along the exit row — the left/right/back/forward
wander comes out of the generator rather than being authored.

The bay is **solved when the player stands on the final cell**, not when the crate merely
arrives there — you have to actually make the last step.

---

## 4. The operator's overlay

The player sees the next cell on the HUD; the physical operator needs it too, since the route
is random. Every time the target changes, the bay publishes a frame through the existing
outbound bridge:

```lua
Bridge.send({
    t = "target", bay = 3, level = 1,
    col = 2, row = 1, step = 3, of = 8, done = false,
})
```

No colour is sent, because any cube will do — the overlay only has to say *where*.

`done = true` with no `col`/`row` means the route is finished.

Notes on how this is wired:

- `Bridge` is **optionally** required (`pcall` on `ServerScriptService:FindFirstChild("Bridge")`),
  because it only exists on branches carrying the real robot link. Without it the bay plays
  exactly the same, just without the overlay.
- Sends are de-duplicated — the same target is never published twice in a row.
- ⚠️ **The Python side needs a matching `t = "target"` handler.** Nothing consumes this frame
  yet; it is emitted and currently ignored.

---

## 5. Architecture changes this bay forced

### 5.1 `BlockSync.CratePlaced` — the snapshot is not the arrival

`CellsChanged` fires as soon as the **cells snapshot** changes, which is the moment the
operator's cube moves on the real table. At that point the arm still has ~5s of carry to do —
and the crate **may never arrive at all**, because a placement guard can refuse it.

Driving the bay off `CellsChanged` produced two real bugs, both caught in testing:

1. A cell the guard had **refused** was marked safe to stand on, with no crate there.
2. An accepted cell went safe ~5s early, and the cooldown on the cell under the player's feet
   started while the new crate was still in the air — defeating §2 entirely.

`BlockSync` now fires `CratePlaced(bayModel, cell)` from inside the delivery's `onArrive`
callback — the point at which the crate is physically seated. **Any obstacle whose timing or
safety depends on the crate actually being there must use this, not `CellsChanged`.**

### 5.2 HUD ownership needed a single-winner rule

Bay 2 introduced `publishObjective`, which only addresses players inside the publishing bay.
That used a padded window so a bay could brief the player on the approach catwalk — but the gap
between bays is `Config.BayGap` = 6 studs and the pad is a whole cell (8), so **neighbouring
bays' padded windows overlap** and both claimed anyone standing between them. Standing at z=57
showed bay 2's callout while walking into bay 3.

`hudBayFor(pos, pad)` now picks exactly one owner: the bay whose body contains you always wins;
outside every body, the bay you are walking **towards** beats the one you just left. Verified
across the corridor — one owner at every position, with the handoff landing on the bay ahead.

### 5.3 `solveMode` and banners generalised

Bay 3 is the second **action** bay (the obstacle owns `state.solved`), so:

- `ownsItsSolve(info)` accepts `"switches"` (bay 1) and `"action"` (bay 3); `checkSolved` skips
  both.
- `state.banner` was hard-coded to `"THROW BOTH LEVERS"` for any switch-mode bay — bay 1's
  requirement, wrong for every other action bay. A bay now supplies its own `banner`, and the
  default still describes a placement bay.

### 5.4 Arming has to trigger from the approach

Every cell is lethal until the first crate lands, so a bay that only armed once somebody was
standing **inside** it could only ever be armed by somebody dying in it. `ARM_PAD = CELL` lets
the player arm it from the catwalk, read the callout, and wait for the first placement.

---

## 6. On-screen objective

| State | Task | Tone |
|---|---|---|
| on the approach, unarmed | `STEP ONTO THE GRID` | danger |
| route running | `BLOCK → COL c, ROW r` + `Step k of n` | danger / warn |
| route exhausted | `STAND ON THE LAST CELL` | warn |
| solved | `CLEARED` | ok |

The countdown shows `CELL GOES LIVE IN` for **the cell the crate just left** — the one the
player is standing on. Showing whichever cooldown expired soonest looked fine until two
overlapped, and then it counted down a cell already behind them, reading `0.3s` while the
ground underfoot still had a full 6s.

A refused placement flashes the reason, e.g. `NOT THE NEXT CELL - COL 3, ROW 0`.

---

## 7. Colour code

| Cell state | Pad |
|---|---|
| live | red, beams on |
| holds the crate | green, beams off |
| cooling down | amber, pulsing — pulse rate jumps for the last `LaserRearmWarnSeconds` |

---

## 8. Verified

Driven through the real `CellEdit` / `DebugHotkey` remotes.

| Check | Result |
|---|---|
| All 9 bays still build | no errors; Bay03 = `LaserWalk`, 85 parts (12 pads, 72 beams) |
| Banner | `LASER WALK - FOLLOW THE CRATE`; bay 1 still `SAW - THROW BOTH LEVERS` |
| Grid lethal before arming | 12/12 pads live |
| Arms from the catwalk | armed at z=57, route generated, target published |
| Wrong cell refused | no crate delivered, **pad stayed LIVE**, target unchanged |
| Any colour accepted | a **blue** crate requested into all four row-0 cells: the route's start cell took it and seated it, the other three refused (11/12 pads still LIVE) |
| Refusal flash | `NOT THE NEXT CELL - COL 3, ROW 0` |
| Correct cell | crate seated in 4.6s, pad → SAFE, HUD advanced to step 2 |
| Cooldown | vacated cell `5.7 → 3.8 → 1.8 → LIVE` (configured 6s) |
| Full route | 8 steps driven, each seating in 3.8–5.3s |
| Route exhausted | `STAND ON THE LAST CELL` |
| Solve | player stepped on final cell → `CLEARED`, 0 live pads, survived |
| Stepping on a live cell | dead in 0.2s |
| Death → reset | route regenerated (step 1 moved from `(3,0)` to `(1,0)`) |
| HUD ownership sweep | exactly one bay at z = −6, 4, 27, 50, 55, 57, 59 |

---

## 9. Bugs found building this (don't reintroduce)

1. **The snapshot is not the arrival.** See §5.1 — the cause of two separate safety bugs.
2. **Padded HUD windows overlap between neighbouring bays.** See §5.2.
3. **A bay whose every cell is lethal cannot arm from inside itself.** See §5.4.
4. **The soonest cooldown is not the relevant cooldown.** See §6.
5. **Hardcoding a route into a test is wrong when the route is random.** A test that assumed
   step 1 was `(3,0)` "passed" against a run whose step 1 was `(2,0)` and masked bug §5.1 —
   read the target off the HUD instead.

---

## 10. Open

- **Nothing consumes the `t = "target"` frame yet.** The Python overlay needs a handler, and
  the frame shape above should be agreed against `PROTOCOL.md` (which lives on the robot side,
  not in this branch).
- **`LaserCooldownSeconds = 6` is unplaytested** against a real operator. It is the bay's whole
  difficulty in one number.
- **Death restarts the route**, which means the operator physically carries the cube back to a
  newly-generated start cell for a mistake the *player* made. Chosen deliberately; it is one
  branch in `disarm()` if it proves too harsh.
- **Routes can be short and straight.** A length-6 roll came out as `(3,0) (2,0) (1,0) (0,0)
  (0,1) (0,2)` — an L, with no doubling back. Raising `LaserRouteMin` or rejecting routes with
  too few direction changes would guarantee the wander.
- **No checkpoint**, as everywhere else.
