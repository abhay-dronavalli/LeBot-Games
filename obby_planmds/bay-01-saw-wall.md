# Bay 1 — Saw Wall

**Status:** built and **solved end to end in Studio** — both levers thrown by a real E-hold,
wall sunk, exit walked. Timings still need a real teleop run.
**Shared systems used:** objective HUD, placement guards, reach gating — all described in
[README.md](README.md) so other bays can reuse them.
**Code:** `lebot_obby/ServerScriptService/HazardManager.lua` → `BUILDERS.Saw`
**Data:** `lebot_obby/ReplicatedStorage/BayData.lua` → `[1]`
**Tuning:** `lebot_obby/ReplicatedStorage/Config.lua` → `SawWall*`

---

## 1. The scenario

You step into the bay and the entrance gate slams down behind you. At the far end,
a wall of chainsaws starts closing in — slowly, because teleoperating a real arm is
slow and the clock has to allow for fumbling.

Two levers are the way out, both mounted too high to reach from the floor:

| Lever | Where | Needs | Does |
|---|---|---|---|
| **A** | left wall, row 1 (deeper in) | stand on **exactly 1 crate**, hold **E** | kills the spinning blades, arms Lever B |
| **B** | right wall, row 0 (by the door) | stand on **exactly 2 stacked**, hold **E** | halts the wall and **sinks it into the floor** |

**A lever belongs to one stand level, not a minimum.** `BayData` gives each lever a
`standLevel` (1 or 2) and the builder derives everything from it — mounting height, the painted
level band on the wall, and the gate. Standing *too high* fails just as standing too low does:
the stacked pair cannot reach down and flip Lever A. That is what makes each lever cost its own
crates, which is the cube-budget argument the whole bay rests on.

The levers are bolted **flush to the bay's side walls**. They used to sit on a 3.5-stud block
jutting into the bay — not for looks, but because the bay had no side walls at all
(`Border.Left/Right` are 0.25-stud floor stripes you can walk over). The Saw builder now puts
real side walls in, so the lever is a backplate on a wall like it should be.

Each lever is a `ProximityPrompt` on the housing: climb to it and hold **E** for
`Config.SawLeverHoldSeconds`. The prompt is only enabled while that lever is armed. An
earlier version threw on `Touched`, which fired the moment any body part grazed the
housing — you could flip a lever by brushing past it.

The sunken wall *is* the exit. There is no separate exit gate — you walk out over
where the wall was.

**The point:** the crates are a **ladder to the answer**, not the answer itself. The
earlier version of this bay had you drop one block on a blade to jam it, which made
the puzzle "pick the right colour." This version makes it "place accurately, fast,
under pressure" — which is the skill a teleoperated arm actually tests.

---

## 2. The cube budget, and why it drives the design

A cell holds one block at level 1 (1 cube) or a stacked pair at level 2 (2 cubes). The wire
format is `{col, row, color, level}`, one entry per cell — but **no obstacle reads `color`**,
so any cube satisfies any cell. `level` is the part that costs something.

So a three-high stack is **not buildable**. Height difficulty comes from *what you
stand on* instead:

| Needs | Crate top | Lever height | Gate |
|---|---|---|---|
| 1 cube (L1) | 6.72 studs | 9.12 | within ±3.02 of 6.72 |
| 2 cubes (L2) | 13.44 studs | 15.84 | within ±3.02 of 13.44 |

**These numbers come from the real cube, not from tuning.** A 48 mm cube at the pinned
mat-to-bay scale is 6.72 studs (see [robot-link.md](robot-link.md) §2), so a pair is
13.44 — and a default jump clears about 12.8 studs of head height, which falls *between*
them. The cube cost is enforced by physical scale: one cube is climbable, a stacked pair
is not. The earlier 4-stud crate needed `minStand` to carry that burden alone.

Verified at the new scale: standing on the floor gates both levers off, one cube passes
A and fails B, a stacked pair passes both.

Lever A costs 1 cube, Lever B costs 2, and the brake crate costs 1 more:

```
cube 1    ->  Lever A step           cell (0,1) level 1
cube 2    ->  brake crate            anywhere in the sweep lane   [optional]
cubes 3+4 ->  Lever B stack          cell (3,0) level 2
```

The two levers were originally on **different colours** because the budget was two cubes per
colour and an all-orange bay would have needed three. That constraint is gone — colour is no
longer checked anywhere — but the split stays, because what actually distinguishes the levers
is the **height you must be standing at**, and that was always the load-bearing part.

---

## 3. Stalling the wall

A crate **can never be destroyed** — the real cube is still sitting on the operator's
table and the game has to mirror it. So stalling is gated on the blades instead, and it
is a **reward for killing them, never a way to skip that step**:

- **Blades live** → the wall cuts straight through without slowing, *and* a crate cannot
  even be placed within `SawWallNoPlaceBand` studs of the blades. The delivery is refused.
- **Blades dead** (after Lever A) → nothing cuts, so the first crate in the path **jams the
  wall** — but only for `SawWallStallSeconds` (10), and **each crate's stall is spent once**.
  When the timer runs out the wall grinds past that crate at full speed and will not jam on it
  again.

The band is measured from the blades, so placing a crate *early*, while the wall is still
far away, is fine. It's only dropping one just in front of live blades that gets turned
away.

A refusal is **deferred, not discarded** — the operator's cube is still on the table, so
`BlockSync` parks it and `retryRejected()` delivers it the moment Lever A changes the
answer.

Because the stall is per crate, the spare cube buys a **second** 10s reprieve further down
the lane — roughly 20s of extra time across the two, which is the real budget for getting
Lever B done.

⚠️ **A crate is a reprieve, not a shield.** This is a deliberate softening of the
*"doesnt jst die standing on the block"* rule: standing on a jammed crate is safe only while
its stall is running. Once spent, the wall resumes and will crush you there. The on-screen
`WALL STALLED - Ns` countdown is the warning, so the death is never unsignalled — but it is a
real way to die on top of your own block, which no other bay allows.

---

## 4. Why the levers can't be cheated

A default Roblox jump from the floor reaches roughly **12.8 studs of head height**,
which would clear both levers with no crates at all. Mounting them higher doesn't fix
it cleanly, and the gantry rails sit at `GantryHeight = 18`.

Instead, a lever only responds if a downward raycast from the player finds a crate
(tagged `IsCrate`, or the legacy `Base`/`Topper` names) under them, and that crate's
top is **within half a cube of the lever's own stand level** — not merely at or above
it. The cube cost is therefore exact in both directions: too high fails like too low.

Lever B is mounted where a single crate cannot reach, so there'd be no feedback at all —
it would just read as broken. A proximity check in the run loop covers that: stand near
an armed lever at the wrong height and
the label reads `STACK HIGHER`.

---

## 5. On-screen objective

The bay drives a HUD (`StarterPlayerScripts/ObjectiveHud`) through the generic
`Remotes.Objective` event, so the player is never guessing what the bay wants:

| State | Task line | Timer |
|---|---|---|
| outside the bay | *hidden* | — |
| blades live | `LEVER A — KILL THE BLADES` | `WALL REACHES YOU IN m:ss` |
| blades dead | `LEVER B — STOP THE WALL` | `WALL REACHES YOU IN m:ss` |
| crate jamming the wall | (unchanged) | `STALLED 0:10`, counting down |
| solved | `CLEARED` | — |

Each line carries a hint naming the wall and what you need to stand on. A refused placement
flashes `BLADES LIVE - CANNOT DROP THERE` under the panel for 2.5s, and on the billboard in
world. The countdown turns red under 10s by itself, whatever the task tone is.

The payload is `{title, task, hint, tone, timer, timerLabel, timerTone, flash}` and firing
`nil` clears the HUD — nothing in it is saw-wall specific, so later bays can reuse it.

## 6. Colour code

Green means **"this is your target right now"** and nothing else is ever green.

| State | Mount | Beacon | Label |
|---|---|---|---|
| Dormant | dark grey | dark | `LOCKED` |
| Armed | green | pulsing green | `LIVE` (or `STACK HIGHER`) |
| Thrown | blue-grey | cold blue | `THROWN` |

A thrown lever deliberately goes **blue, not green**, so there are never two greens on
screen at once.

---

## 7. Geometry

Bay 1 spans `z = 0..24`, `x = 0..32`. Entrance at `z = 0`.

```
  z=0   ENTRANCE (gate seals behind you)
        row 0   Lever B (right wall, x=31.32, y=15.84)  crate cell (3,0) L2
  z=8   row 1   Lever A (left wall,  x=0.68,  y=9.12)   crate cell (0,1) L1
  z=16  row 2
  z=22  <- WALL STARTS HERE, closes toward z=2.5
```

The wall travels **far end → entrance**. Two things follow from that:

1. It reaches row 1 before row 0, so **Lever A is the timed one** and Lever B is reached last.
2. A's crate jams the wall at `z≈15.1`, but only for 10s — so the finish stays a race.
   Dropping the spare cube further down the lane buys another 10s.

The wall is **16 studs tall and cannot be vaulted** — a default jump clears about 12.8 studs
of head height, and the old 7.4-stud wall was therefore a hurdle rather than a wall. The only
way past is to sink it.

It runs in **side channels** rather than spanning the bay edge to edge: it covers x 1.1–30.9
against a 32-wide bay, so it sweeps *past* the wall-mounted levers at x 0.68 and 31.32 instead
of through them. The 0.4-stud gap at each side is far too narrow to walk through.

The handle rotates about **Z**, so it swings out into the bay toward whoever is standing in
front of it. An earlier version rotated about X, which tipped each lever down the lane and
made them look aimed at nothing in particular. Measured: throwing Lever A moves the knob from
`(3.15, 10.00, 12.00)` to `(5.41, 8.42, 12.00)` — X moves toward the bay centre, Z is
unchanged.

---

## 8. Timing

`Config.SawWallSeconds = 75` is the whole bay's difficulty in one number. It was 60; the wall is no longer vaultable, so every crossing has to be earned by actually solving the bay, and the extra 15 s is the room that costs.

The arithmetic that matters: one `SkyArm.reachAndPlace` is **~5.5s of animation**, and
the job queue **serializes** them (no overlap). A level-2 cell is one arm trip, not two.
So three placements cost **~17s of a 30s run** before the player has climbed anything.

30s played too fast once the no-place band went in, because stalling is no longer
available to buy that time back — hence 60. Retune after the first real teleop run; the
number is still a placeholder for human fumbling time, which hasn't been measured.

The wall advances off **measured elapsed time**, not tick count. `task.wait(0.05)` sleeps
longer than 0.05s, which made a nominal 30s traverse take ~34s before this was fixed.

---

## 9. Architecture change this bay introduced

Bay 1 is the first obstacle solved by an **action** rather than a **placement**, so it
opted out of the usual path:

- `BayData[1].solveMode = "switches"`
- `checkSolved` is skipped for that bay; the builder sets `state.solved` itself
- `solveCells` becomes an advisory "stack here" hint, not the win condition
- all solve/unsolve goes through one `state.setSolved`, shared by both routes

**Consequence:** clearing cells cannot un-solve a switch-mode bay. Without a reset the
bay stays open for the rest of the session and the wall sits frozen wherever it stopped.
The **R hotkey** now resets every bay (`state.reset`).

**Known caveat:** obstacles that present "solved" as a one-shot tween (the laser grid
fading out) do not animate back on reset. Their run loops resume but the visual stays
cleared. Only the saw bay rebuilds itself properly.

---

## 10. Verified

Driven through the real `CellEdit` remote, not by requiring modules — `execute_luau`'s
Server datamodel is a separate Luau VM with its own module cache, so a direct `require`
gets a *different instance* and proves nothing.

| Check | Result |
|---|---|
| Entry path clear | first obstruction at z=21.4 (the wall); doorway volume empty |
| Enter → seal | gate y=−7 → +7, wall begins closing |
| Lever B while dormant | refused, `LOCKED` |
| Lever A from one crate | threw; blades dead, B goes `LIVE` |
| Wall after A | 21.3 → 18.8 → 17.5 → 16.2 → **15.1 → 15.1 → 15.1** (jammed) |
| Player on that crate | survived |
| Lever B from the pair | wall sinks below the floor, `CanCollide = false` |
| Console | `Lever A thrown` → `Lever B thrown` → `Saw SOLVED` |
| Wall speed | 0.328 studs/s vs 0.325 target (measured at the old 60 s; 75 s not re-measured) |
| Crate in front of live blades | **refused**, not delivered |
| Crate clear of the wall | delivered normally |
| Lever A via E-hold | threw; blades dead, B's prompt enabled |
| Parked rejection after A | delivered by `retryRejected` |
| Stall after A | held at z=15.09 for ~10s, then resumed at 0.314 studs/s |
| Stall spent once | wall passed the same crate without re-jamming |
| HUD outside bay | hidden |
| HUD task switch | `LEVER A` → after throw → `LEVER B`, hints follow |
| **Wall height** | 16 studs, top at 16 vs a ~12.8 stud jump — **not vaultable** |
| **Wall clears the levers** | wall spans x 1.1–30.9; levers at x 0.68 / 31.32 |
| **Side walls exist** | 2, 16 studs, collidable |
| **Level bands** | painted at y 6.92 and 13.64 |
| **Exact-level gate** | A: floor ✗, 1 crate ✓, 2 stacked ✗ · B: floor ✗, 1 ✗, 2 ✓ |
| **Sink depth** | wall top ends at −1.5, below the floor |
| **HUD checklist** | both levers listed with state; `1:15` counting down |
| **One crate size everywhere** | solo and live both build 6.72-stud cubes; L2 is two of them |
| **FULL SOLVE (E-held)** | block → stand → hold E → `Lever A thrown, blades dead` (8/8 blades) |
| | stack → stand → hold E → `Lever B thrown, wall halted and lowering` → **`Saw SOLVED`** |
| Wall after lever B | sank to top −1.50, below the floor, `CanCollide = false` |
| Exit lane | z 14–26 clear of collidable parts at knee height; player alive |
| HUD on clear | `CLEARED`, both steps `[x] done` |
| HUD countdown | `0:58` → `0:56` over 2s, and `STALLED 0:10` during a jam |
| Refusal flash | `BLADES LIVE - CANNOT DROP THERE` |
| Lever swing axis | knob moves in X, Z unchanged |

---

## 11. Bugs found building this (don't reintroduce)

1. **Wall blocked entry.** It started 2 studs inside the door, full width, `CanCollide`
   on. Missed because the test *teleported* to row 2 and never walked through the door.
   → Always exercise the real entry path.

2. **Stale character in tests.** `Health = MaxHealth` does not revive a *destroyed*
   Humanoid, so the bay read as empty and nothing armed — the test looked like a pass.
   → Use `pl:LoadCharacter()` and confirm alive before asserting.

3. **Duplicate crates.** `BlockSync` guarded replacement with `existing.Parent`, but a
   crate queued in the arm has no Parent yet, so the check couldn't tell "not placed yet"
   from "already destroyed" — and skipped exactly the queued ones. Cycling a cell through
   five colours in half a second left **three crates stacked** in it. Now flagged
   `Superseded`, with `SkyArm` dropping those jobs.

4. **Server `MoveTo` does nothing** for a player-controlled character — the client
   overrides it. Use geometric checks (raycast / `GetPartBoundsInBox`) to prove a path
   is walkable.

5. **A closure captured a nil global.** The placement guard reads `running`, which was
   declared *below* it, so inside the closure it resolved to a nil global — `not running`
   was always true and the guard allowed every placement. It looked like the guard simply
   didn't work. Lua locals are only visible to closures created *after* the declaration.

6. **`ProximityPrompt:InputHoldBegin()` is client-side.** Calling it from the server does
   nothing; `Triggered` only fires when a real client completes the hold.

---

## 12. Open

- **75s and the 10s stall are unvalidated.** Both need a real teleop run to tune. The wall
  speed was measured at the old 60 s and has not been re-measured since.
- **The stall and the no-place band have not been re-verified** since the wall was rebuilt at
  16 studs in side channels. They were verified against the old 7.4-stud full-width wall, and
  the geometry they key off has changed.
- **Lever heights (9.12 / 15.84) are unplaytested.** They are derived from `standLevel` and
  the real cube size rather than chosen, so they should be right by construction — but the
  *feel* of reaching them is untested.
- The gate is **height-only** — no colour anywhere, matching the project-wide rule that any
  block satisfies any cell. That is also what makes this bay immune to the vision system
  misnaming a cube. Do not be tempted to add a colour test.
- **No checkpoint.** Dying respawns at world spawn; you walk back through the bays.
  `GameState` doesn't exist yet.
- **`ActiveBayTracker` doesn't exist**; `RunControl.activeBay` stands in and the debug menu
  drives it, so every bay is reachable — see [debug-menu.md](debug-menu.md). Previously only Bay 1 was
  wired to the arm.
- **Two players** — not yet decided whether to fold into `ActiveBayTracker` or stay
  single-runner.
- **The guard allows everything while the bay is dormant** (`not running`). Harmless
  today — on arming the blades are live, so a pre-placed crate is cut through rather than
  stalling anything — but worth revisiting if the arming rules change.
