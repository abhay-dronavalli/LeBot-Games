# Bay 2 — The Void

**Status:** built and verified in Studio. Solvable end to end.
**Shared systems used:** objective HUD (and its new arbitration), placement grid, `BlockSync`
crate delivery — all described in [README.md](README.md).
**Code:** `lebot_obby/ServerScriptService/HazardManager.lua` → `BUILDERS.Void`
**Data:** `lebot_obby/ReplicatedStorage/BayData.lua` → `[2]`
**Tuning:** `lebot_obby/ReplicatedStorage/Config.lua` → `Void*`

---

## 1. The scenario

The floor over the first two rows of the bay is simply gone. There is no timer, no
blade, nothing chasing you — the obstacle is the gap, and the only way across is the
two crates the operator puts down for you to jump between.

| Step | What happens |
|---|---|
| You walk up | The HUD names the first cell: `BLOCK → COL 1, ROW 0` |
| Operator places it | A crate lands in the void and becomes footing |
| HUD advances | `BLOCK → COL 1, ROW 1`, hint: *one more block, then jump from block to block* |
| Operator places it | Bay solves; edge striping turns green; `CLEARED` |

**The point:** bay 1 tests placing accurately *under time pressure*. This bay strips the
pressure out and tests placement as **load-bearing** — get the cell wrong and the player
has nowhere to stand. It is the first bay where a crate is literally the floor.

---

## 2. Why the gap can't just be jumped

This was the one number worth getting right, and it is measured, not guessed. From the
place's own settings:

```
Gravity 196.2 , JumpHeight 7.2 , WalkSpeed 16
  jump velocity  = sqrt(2 * 196.2 * 7.2)  = 53.15
  airtime        = 2 * 53.15 / 196.2      = 0.54 s
  flat distance  = 0.54 * 16              = 8.67 studs
```

The void over rows 0–1 is **16 studs** — nearly twice that. So the crates can't be
skipped, and there is no need to widen the void to all three rows or raise the far side.
Keeping row 2's floor also gives the player somewhere to land, and keeps the bay solvable
on **2 cubes**, which is what every bay is designed around.

> ⚠️ **The raycast below predates two changes and no longer describes the bay.** It was
> measured against a 4-stud crate sitting *on* the floor. The crate is **6.72 studs** now
> (the real cube's size — [robot-link.md](robot-link.md) §2), and this bay sets
> **`CrateSink`** to one full cube, so the bridge is **flush with the walkway** instead of
> standing a cube proud of it. Kept because the conclusion it reached — every hop inside
> 8.67, the gap as a whole far outside it — is the thing that had to be true, and still is,
> by a wider margin.
>
> ```
> z 26.0..29.5   surface y=0.0     <- approach catwalk
> z 30.0..31.5   GAP  2.0 studs
> z 32.0..36.0   surface y=4.0     <- crate at cell (1,0)   [4-stud crate, resting ON the floor]
> z 36.5..39.5   GAP  3.5 studs
> z 40.0..44.0   surface y=4.0     <- crate at cell (1,1)
> z 44.5..45.5   GAP  1.5 studs
> z 46.0..53.0   surface y=0.0     <- floor resumes, exit at z=54
> ```

What the geometry is now, derived from the cube size and the baked anchors (row centres at
z = 34 / 42 / 50, a 6.72-stud cube, sunk one cube so its top is at y = 0):

```
z ..30.00      surface y=0.0     <- approach catwalk, near lip
z 30.00..30.64 GAP  0.64 studs
z 30.64..37.36 surface y=0.0     <- crate at cell (1,0), FLUSH with the walkway
z 37.36..38.64 GAP  1.28 studs
z 38.64..45.36 surface y=0.0     <- crate at cell (1,1), flush
z 45.36..46.00 GAP  0.64 studs
z 46.00..54.00 surface y=0.0     <- floor resumes, exit at z=54
```

**The bridge is now a flat walk, not three hops.** A 6.72-stud cube in an 8-stud cell leaves
0.64 of clearance per side, so the two crates and the two lips form a near-continuous surface
at one level — the gaps are 0.64 / 1.28 / 0.64 against a 8.67-stud jump, which is a stride
rather than a jump. That is a *better* fit for what this bay is about: the difficulty is the
operator getting the cells right, and the player should not also be fighting a platforming
test. The 16-stud void is still nearly twice a running jump, so nothing can be skipped.

**Not re-measured in Studio since the rescale** — the numbers above are derived, not
raycast. Worth re-running the sweep.

**The bay is hard for the operator and easy for the player**, which is the split this
project wants.

---

## 3. The cube budget

Two cubes, any colour, on two level-1 cells:

```
cube 1  ->  cell (1,0)   stepping stone 1
cube 2  ->  cell (1,1)   stepping stone 2
```

Nothing spare. Both cells are column 1 so the route is a straight line down the middle of
the bay — a zig-zag would have been prettier but costs reach accuracy for no gameplay gain.

A four-block version was considered and rejected: the extra hops don't make the bay teach
anything new. (It was once rejected partly because it needed per-cell colours in
`checkSolved`; that objection no longer applies, but the design one still does.)

---

## 4. Safe footing

This bay satisfies the global safe-footing rule for free, and is the cleanest example of
it: **nothing in the bay is lethal except the drop**. There are no blades, beams or
crushers, so the crate you are standing on can never turn on you. Contrast bay 1, which is
the one deliberate exception to that rule.

The only way to die is to fall, and the kill plane is 48 studs down
(`Config.VoidShaftDepth`), well clear of the geometry, so the death reads as falling rather
than as touching scenery. Verified: dropped in at (16, 6, 38) → dead in 0.8s.

---

## 5. On-screen objective

No countdown — this bay has no clock of its own and inventing one would be adding a
mechanic rather than building an obstacle. The task line carries the **cell callout**
instead, which is exactly what the player needs to shout at the operator:

| State | Task line | Tone |
|---|---|---|
| outside the bay | *hidden* | — |
| nothing placed | `BLOCK → COL 1, ROW 0` | danger |
| one placed | `BLOCK → COL 1, ROW 1` | warn |
| solved | `CLEARED` | ok |

The hint under it reads *"No floor for 16 studs. Call out both cells — the crates are the
bridge."*, then *"One more block, then jump from block to block."*, then *"The bridge is in
— jump across to the exit."*

In world, each unfilled solve cell carries a **crate-sized hologram**, amber, labelled
`BLOCK (1,0)`, so the cell can be read off the floor without the debug grid. Each one vanishes
as its cell is filled. It used to be tinted to the colour the cell wanted; with any block
accepted, that would have been sending the operator after a cube they don't need.

---

## 6. Colour code

The hazard striping along both lips **is** the bay's state readout:

| State | Lip dashes |
|---|---|
| gap open | amber |
| bridged | green |

Consistent with bay 1's rule that green means "done / safe" and nothing else is green.

---

## 7. Geometry

Bay 2 spans `z = 30..54`, `x = 0..32`. Everything is derived from `coverRows`, so changing
that one field in `BayData` moves the geometry with it.

```
  z=30  ENTRANCE / near lip          <- approach catwalk ends here
        row 0   cell (1,0)  crate 1      VOID
  z=38  row 1   cell (1,1)  crate 2      VOID
  z=46  far lip                       <- floor resumes
        row 2                            SOLID
  z=54  EXIT
```

The builder shrinks the baked `Floor` part down to the kept rows (`32 x 1 x 8` centred at
z=50) rather than hiding it, and that calculation is absolute rather than relative, so
re-running the builder is idempotent.

It also sets **`CrateSink = Mapping.cubeStuds()`** on the bay model, which is what makes the
two crates land flush with the walkway rather than a cube above it (§2). That attribute is read
by `BlockSync.cellToWorld`, so it applies on both the solo and the live path.

Below the opening: four dark shaft walls, cut-edge fascia showing the slab thickness at
both lips, three red warning lights going down, and the kill plane. All of it is
`CanCollide = false` so nothing catches a falling player half way down.

---

## 8. Architecture changes this bay forced

### 8.1 The arm could only ever reach Bay 1

`DebugMode` hard-coded `targetBay = Bay01`. The quick-travel number keys moved the *arm*
but not the delivery target, so you could stand in bay 2, edit cells, and watch the crates
land in bay 1 behind you. **Every bay past the first was unreachable by the real flow.**

`DebugMode` now keeps one `activeBayIndex` that the number keys and `N` move, and each bay
keeps its **own** cell state — sharing one table would make `BlockSync`, which diffs per bay
model, see every cell vanish from the bay you just left and have the arm dutifully unload
it. This was a minimal stand-in for `ActiveBayTracker`, which is **built** now — the active
bay lives in `RunControl`, the tracker drives it from the runner's position, and the debug menu
drives the same call ([debug-menu.md](debug-menu.md) §5).

Quick-travel also now lands you on the approach catwalk (`zStart - 3`) instead of
`zStart + 2`, which in this bay was thin air over the void.

### 8.2 The objective HUD had no arbitration

`Remotes.Objective` is one channel, and bay 1's loop broadcast a **clear** to every client
every 0.2s whenever its own bay was empty. While bay 1 was the only driver that was
invisible. The moment bay 2 started publishing, bay 1 wiped its callout between frames and
bay 2's HUD only appeared in the gaps — measured as alternating payload/nil.

No bay broadcasts any more. `publishObjective(i, payload, pad)` addresses only the players
inside bay `i`, and clears only a player it was itself last showing something to. That also
makes bay 1's own stated intent — *"a player standing outside the bay isn't told to do
anything"* — actually true, which broadcasting never delivered.

**Any new bay must use `publishObjective`, never `FireAllClients`.**

### 8.3 Presentation must not hang off `state.solved`

`buildBay`'s `setSolved` only calls `onSolved` on the way **in**. Hanging the lip colour off
it left the bay still showing "cleared" after a crate was lifted back out. The Void drives
its presentation from what has actually landed (`refresh()`), so it survives un-solving.

---

## 9. Verified

Driven through the real `CellEdit` / `DebugHotkey` remotes, not by requiring modules.

Measured before the cube rescale and the scope cut to four bays, so the heights and the bay
count below are historical. Everything structural — the floor cut, the delivery target, the
arbitration — is unchanged.

| Check | Result |
|---|---|
| All bays still build | `one obstacle per bay built for all 9 bays`, no errors *(4 bays now)* |
| Floor cut back | `32 x 1 x 8`, z 46..54, collidable |
| Void empty before placing | 0 collidable parts in z 30..46 |
| Crate delivered to the right bay | Bay01=0, **Bay02=2** (was the hard-coded bug) |
| Crate at rest | base y=2.00, top=4.00, `CanCollide=true` *(4-stud crate, pre-`CrateSink`; the top is at y=0 now — see §2)* |
| Delivery time | 3.7s and 4.4s per crate |
| Route gaps | 2.0 / 3.5 / 1.5 studs — all under the 8.67 jump *(0.64 / 1.28 / 0.64 now, and flat)* |
| Gap uncrossable unplaced | 16 studs vs 8.67 |
| Kill plane | dropped at (16,6,38) → dead in 0.8s |
| HUD on approach, unsolved | 14/14 payloads `COL 1, ROW 0`, **zero** interleaved clears |
| HUD after one crate | `COL 1, ROW 1`, tone warn |
| HUD solved | `CLEARED`, tone ok |
| Lips on solve | 16 green / 0 amber, holograms hidden |
| Un-solve (clearing (1,1)) | lips 0 green / 16 amber, 1 hologram back, HUD reverts |
| Re-verified after colour requirements were dropped | solved on **2 blue crates**, seated y=2.00, 16 green lips |
| Bay 1 regression | `LEVER A — KILL THE BLADES`, countdown live at 57.1s |
| Bay with no driver | HUD hidden *(bay 4 at the time — it drives its own HUD now that DarkZone lives there)* |
| Returning to bay 2 | bay 2 takes the channel back, 14/14 clean |

---

## 10. Bugs found building this (don't reintroduce)

1. **Polling for a crate catches it mid-carry.** A test that waited for a crate "near the
   cell" found it at `y=8.64` — in the gripper, hovering, on its way down. Wait for it to be
   *at rest* (`|y - 2| < 0.1`), not merely present.

2. **Lip colour hung off `state.solved`** and so never came back on un-solve — see §8.3.

3. **A dead test character silently fails every occupancy check.** `occupantsOf` excludes
   `Health <= 0`, so a test that wandered through bay 3's lasers reported "HUD hidden" and
   looked like an arbitration bug. Confirm the character is alive before asserting, and
   remember `Player:LoadCharacter()` is **server-only** — calling it from the client throws.

4. **Diagnosing from a screenshot got the cause wrong.** The crates render washed-out white
   and the obvious suspect was the new shaft lights; capping their range changed nothing.
   The actual cause is **bloom** (Intensity 1.0, Size 24) blooming off the crate's own neon
   top stripe — pre-existing in `BlockSync`, identical in every bay. Measure before
   attributing.

---

## 11. Open

- **Crates read as white, not as their colour**, because of bloom off their neon stripe
  (§10.4). Affects every bay. It no longer breaks anything — no obstacle requires a colour —
  but the crates look washed out: shrink the stripe, drop `Bloom.Intensity`, or raise
  `Bloom.Threshold`.
- **Rapid colour cycling can strand a crate.** Cycling one cell through 7 colours in ~2s
  left an orphaned teal crate parked in the cell. `BlockSync`'s `onArrive` guards on
  `crateModel.Parent`, but a job already *in flight* when it is superseded parents the crate
  itself and then lands it. In this bay that orphan is a free stepping stone. Pre-existing
  and shared with bay 1; the real robot feed won't do it, but the debug editor will.
- **No checkpoint.** Falling in respawns you at world spawn and you walk back. `Bay02` has a
  `Checkpoint` part at z=30.5 that nothing reads yet.
- **No reason to hurry.** Deliberate for now — bay 2 is the "learn the mechanic" bay — but it
  means the bay has no failure state other than falling.
