# The robot link — real arm into the obby

**Status:** built and verified end to end against a protocol-faithful mock — the link, the arm
mirror, crates driven by real cubes, and the solve chain through to a bay reading `CLEARED`.
Not yet run against the real robot.
**Code:** `lebot_obby/ServerScriptService/{Bridge,ArmMirror,BridgeFeed,BlockSync}.lua`,
`lebot_obby/ReplicatedStorage/Mapping.lua`
**Upstream:** the `robot-roblox-bridge` branch (orphan history — no merge base with `main`)
**Wire format:** that branch's `PROTOCOL.md`, version 1

---

## 1. What the game actually is

Two players. **Player 1** is the runner — the perspective the bays were built for. **Player 2
is the overseer**, and their only input device is the real SO-101 arm: they place physical
cubes on a 4×3 mat, the Sky Arm mirrors their hands live, and crates appear in the bay. The
debug cell editor was always a stand-in for a person at a robot arm.

That settles a question the obby had left open. `ServerScriptService.SkyArm` *simulates* an
operator — it animates a crate delivery with its own IK and a serialized job queue. There is a
real operator now, so an animated reach would re-enact something player 2 already did with
their hands. **`SkyArm` is now the solo/DebugMode path; `ArmMirror` is the live one**, and only
one is visible at a time.

It also hands us the delivery animation for free. A `held` block follows the jaw as an
unanchored `AlignPosition` platform, so player 2's real carry motion *is* the crate's flight
path — and a player can stand on it. **The crane lift stops being a Bay 9 finale and becomes a
verb available in every bay.**

## 2. The scale is pinned, not chosen

The upstream branch treats `STUDS_PER_MM` as a free parameter (it ships 0.46). Here it is not.
The mat's 4×3 grid has to land on a bay's 4×3 grid of `Config.CellSize` cells:

```
studs per mm = Config.CellSize / grid.cell_mm = 8 / 57.15 = 0.1399825
```

Verified against the baked `Cell_c_r` anchors: **all 12 mat cell centres land on their anchor
to within 2.4e-07 studs**, and `Mapping.cellOf` round-trips every one. Two things fall out,
both lucky:

| | |
|---|---|
| A 48 mm cube is **6.72 studs** | One cube is climbable against the ~12.8 studs a default jump clears; a stacked pair (13.44) is not. That is exactly Bay 1's two-lever gate, arriving from the real scale rather than a tuned constant |
| The arm base lands at **X = 16.00** | The exact centre of the bay's 32-stud width |

`Mapping.ORIGIN` is derived from the active bay's `Cell_0_0` anchor rather than hardcoded, so
following the player from bay to bay is one `setActiveBay` call and the baked geometry stays
the single source of truth.

## 3. Orientation and index conventions

| Wire | Obby | Note |
|---|---|---|
| mat row A, B, C (A nearest the arm) | row 0, 1, 2 (0 nearest the entrance) | **A → row 0.** Both grids then increase together, so there is no axis flip anywhere |
| mat col 1–4 | col 0–3 | The wire carries millimetres; the 1-based numbers are only printed labels |
| `level` 0 = on the paper | `level` 1 = one cube | **Off by one.** `obby = wire + 1`, clamped at 2 — three-high does not exist on the real table |
| `blocks[]`, one entry per cube | `cells[]`, one colour per cell | Group by cell, take the bottom cube's colour |
| `held: true` | *excluded from cells* | Or a pick-and-place reads as a removal followed by an add |

`Mapping.cellOf` deliberately uses the same floor arithmetic as `world.py`'s `_cell_of`, so
the two sides agree on the boundary case instead of each rounding its own way.

## 4. How the arm is drawn — `Config.ArmStyle`

**`"gantry"` is the default and the one we use.** The Sky Arm hangs from the ceiling rails,
slides along the roof between bays, and is sized to the room. The real arm drives it **by the
tip**: wherever the real jaw is, this jaw goes, solved through `SkyArm`'s existing IK. The pose
is not joint-for-joint identical, but it reaches where the real arm reaches, which is what
reads as mirroring — and it keeps the sliding-window crane the plan always described.

`"mirror"` is the literal stick figure (`ArmMirror`), true SO-101 proportions, joint for joint.
It is more honest and it does not fit: see below. Kept because it is verified and may be wanted
once the shell is rebuilt.

**Height is scaled separately from the floor plan, and only height.** The horizontal scale is
pinned by the cell grid and must not move; vertical is pinned by nothing, and at the same
0.1399 the arm's 306 mm of reach is 43 studs — taller than the warehouse.
`Mapping.HEIGHT_PER_MM` is `(GantryHeight - 4) / 250`, so 250 mm of real lift is 14 studs and
stays under the rails. It does **not** touch a resting cube, whose height comes from its stack
level — 6.72 and 13.44 studs are untouched and Bay 1's lever gate is unaffected. Only a held
cube and the arm's own points use it, and both must agree or the jaw and the cube it carries
drift apart.

Measured in gantry mode: rig spans **6.97 → 19.95 studs** against a 28-stud ceiling, trolley
slides the full **24 studs** of rail as the operator works across the mat, and all nine bays
centre to within 0.5 studs.

## 5. What a literal mirror would cost

The SO-101's pan axis is 69 mm off the paper and its wrist reaches 306 mm. At the pinned scale
that is a **43-stud arm whose shoulder sits 9.7 studs up** — a table arm reaching up and over,
*not* the ceiling-gantry arm `Config.GantryHeight` was sized for. Measured in Studio, the rig's
vertical extent was 0 → 38.8 studs mid-pose.

Two consequences, both for the shell regeneration:

- **Headroom.** `WallHeight` 28 is ~15–22 studs too short. Needs ~50.
- **Footprint.** `Mapping` puts the base 9.34 studs *behind* the bay's entrance edge, because
  the real arm sits 44.5 mm off the sheet. The catwalk is only `BayGap = 6` studs, so for bays
  2–9 the arm would stand **inside the previous bay** — which player 1 may still be in. It
  already collides with `Shell.EndCapBack` at Z = −10 for Bay 1.

  `BayGap` must be **≥ 12** for a slim mast to fit entirely in the catwalk (9.34 setback +
  half the mast). That makes `BayPitch` 36 and the course 312 studs instead of 284.

The obby's own `SkyArm` dodged all of this with a trolley that slides in X, so it only ever
spans a row offset of ≤8 studs — which is why its links could be 35% shorter. A mirror cannot:
the real arm has no trolley.

## 6. Risks this surfaced

**Colour is not reliable, and bays 2–9 solve on colour.** There is **no ArUco on the cubes** —
AprilTags are only on the four mat corners, and cube identity comes from colour-blob perception
plus nearest-neighbour association. The palette has nine names (`red, orange, yellow, green,
teal, light blue, blue, purple, pink`) against the obby's seven, and `light blue` (hue 250) sits
18° from `blue` (268). One misnamed cube makes a placement bay unsolvable.

**Bay 1 is immune by luck.** Its lever gating is `supportHeight(ch) < lv.minStand` — height
only. The colours in `BayData[1].levers` are advisory. Worth preserving deliberately as bays
2–9 get their redesign pass.

**The sweep un-solved every placement bay — found, reproduced, fixed.** To advance, player 2
must clear the real mat and re-place for the next bay; there are only two cubes of each colour,
so the cubes holding one bay open are the ones the next bay needs. Bays 2–9 solve by placement
and `checkSolved` un-solved when cells cleared, so the sweep re-armed every bay behind player 1
— the void opening back up under someone walking out of a bay they had already cleared.

Measured on Bay 2 before the fix:

```
  start:  "VOID  -  RED x1"
   8.9s   crates=2  -> "VOID  -  CLEARED"
  14.4s   crates=0  -> "VOID  -  RED x1"      <- the mat sweep re-armed it
```

`HazardManager`'s `CellsChanged` handler now returns early when `state.solved` is already
true, so a solved placement bay **latches**. After the fix, same scenario: solved at 4.7 s,
mat swept to empty while solved, label stayed `CLEARED`. Switch-mode bays were already immune,
which is why only that branch needed it; the R hotkey is still the way to genuinely un-solve.
The mock keeps a sweep step in its script so this cannot silently regress.

## 7. Verified

Driven against `tools/mock_bridge.py`, which speaks PROTOCOL.md v1 with the real grid numbers
from `robot/assets/workspace_sheet.json` and scripts Bay 1's exact solution.

| Check | Result |
|---|---|
| `CreateWebStreamClient` exists | yes, Studio 0.743 — plan §0's transport risk is closed |
| `HttpService.HttpEnabled` | was **false**; setup step 1, now on |
| Connect + hello | `source=mock protocol v1, 6 effects` |
| Grid read from hello | 4×3, 57.15 mm cells, origin (25.40, 22.23), cube 48 mm |
| Scale | 0.139983 studs/mm → cube 6.72, stack of 2 = 13.44 |
| Cell mapping | **12/12 anchors, worst error 2.38e-07 studs** |
| `cellOf` round-trip | all 12 cells agree; no warnings |
| Tray point reads off-grid | true |
| Blocks → cells | `#1 orange (0,1) L1`, `#4 red (3,0) L2` — Bay 1's solve |
| Stacking | `max_wire_level=1` (= obby L2) |
| Held block | reported, and reports `grey` as the protocol says |
| Jaw arrives at the cell | `tip=(4.0, 4.3, 12.0)` vs `Cell_0_1` anchor `(4, 0, 12)` |
| Backpressure | gap of 39 frames opened at startup then **stopped growing** (2342 received / 2303 applied) — no queue buildup |
| Arm vertical extent (`mirror`) | 0 → 38.8 studs against `WallHeight = 28` — too tall |
| **Arm vertical extent (`gantry`)** | **6.97 → 19.95 studs, clear of the 28-stud ceiling** |
| Trolley travel | full **24 studs** of rail (limits 4..28) as the operator works the mat |
| Bay centring | all nine within 0.5 studs of the bay centre |
| Cube in its cell | 6.72 studs in an 8-stud cell, **0.64 clearance per side** |
| Crate heights after the rescale | `(0,1)` top 6.72, `(3,0)` top 13.44 — Bay 1's gate intact |
| Source round-trip | all 12 modules byte-identical between disk and Studio |
| **Crates from real cubes** | cube appears, is carried, lands on the anchor, stacks, and is swept away |
| Resting cube on its anchor | `(4.00, 3.36, 12.00)` for `Cell_0_1`, top 6.72 |
| Stack | second cube at top **13.44**, exactly two cube heights |
| Carried cube tracks the jaw | mean error **1.30** studs, worst 2.14 (60 studs/s cap) |
| Reach gating sees live cubes | floor → 0 · one cube → 6.72 · stacked pair → 13.44 |
| Bay 1's gate at the real scale | floor: A✗ B✗ · one cube: A✓ B✗ · pair: A✓ B✓ |
| Solve chain, Bay 2 | `VOID - RED x1` → **`VOID - CLEARED`** with 2 crates down |
| Latch after the mat sweep | stays `CLEARED` at 0 crates (was re-arming — see §5) |
| `DebugMode` stands down | prints and returns when `Config.LiveFeed` is on |
| Console | no errors, no `HazardManager` warnings |

## 8. Not built yet

- **Shell regeneration** at `WallHeight ≈ 50`, `BayGap ≥ 12`, with the generator extracted into
  `build/` so `Config` becomes authoritative again (§4). The arm currently pokes through the
  roof and its base intersects `Shell.EndCapBack`.
- **`ActiveBayTracker`** — now on the critical path, not optional: it is what makes one mat
  serve nine bays. `Config.LiveBay` is the hardcoded stand-in and is the shape it should take.
- **The overseer client** — role assignment, spectator camera, the §8 ghost minimap as player
  2's instrument panel, and a `CONTROLLER OFFLINE` banner. `BridgeFeed` already tracks and
  prints that state; nothing surfaces it on screen.
- **The sabotage channel** — `Bridge.sendEvent` with §9's telegraph/no-overlap/cooldown rules
  and a gate on `held`, so an effect never fires into player 2's hands mid-carry.
- **A real Bay 1 solve** — the levers need a client holding E (`ProximityPrompt:InputHoldBegin()`
  is client-side and does nothing from the server), so the lever throw itself is still
  unexercised on the live path. The gating that *decides* whether a throw is allowed is
  verified.
- **Anything against real hardware.** Every number here came from the mock.

## 9. Testing without the robot

`tools/mock_bridge.py` needs only `websockets`. The real `bridge.main --source mock` needs the
whole robot package (numpy, opencv, lerobot) and only runs on the robot laptop, so the Roblox
side could not otherwise be developed or verified on its own machine.

```
python tools/mock_bridge.py            # Bay 1's solution on a loop, with a sweep
python tools/mock_bridge.py --idle     # just wave the arm, place nothing
```

It is faithful where it matters — the real grid spec, a real 2-link-plus-azimuth FK chain so
the jaw actually arrives at the cell it is placing into, stable ids, `level`, `held`, `visible`,
and `grey` while carried — and crude everywhere else.

## 10. Bugs and gotchas found here

1. **`HttpEnabled` was off.** Nothing connects, and the failure looks like a bad URL.
2. **PROTOCOL.md's prose and hello example are stale.** They describe a portrait sheet with a
   3×3 grid; `HANDOFF.md` says the 3×3 hardcoding was removed and `workspace_sheet.json` is
   3 rows × 4 cols landscape. **Read the live hello frame, not the doc.**
3. **The arm base collides with `Shell.EndCapBack`** (§4), and would stand inside the previous
   bay for bays 2–9.
4. **`obby_plan.md` §12 is superseded** by PROTOCOL.md v1 and was still being described as
   "unchanged, still the contract" — see the correction in [README.md](README.md).
5. **A welded decoration part left anchored makes the whole assembly immovable.** The cube's
   neon stripe was built `Anchored = true` and welded to the base; an assembly containing any
   anchored part has **infinite mass**, so unanchoring the base for a carry changed nothing and
   `AlignPosition` drove it nowhere. It read as a broken constraint — but the goal attachment
   was sitting correctly at the jaw the whole time, and `AssemblyMass` was `inf`. **Check
   `AssemblyMass` before suspecting the constraint.**
6. **A cube built mid-carry starts at the origin** and gets hauled across the map by the
   constraint. Snap a fresh part to its target before unanchoring it.
7. **Firing `CellsChanged` at the wire's 30 Hz** re-runs every bay's solve check thirty times a
   second and strobes the labels. Positions update per frame; the *cell* view changes only when
   a cube is set down or lifted, so it fires on change only.
8. **`execute_luau`'s Server datamodel is a separate Luau VM**, so `require(BlockSync)` there
   gets a different module instance with its own BindableEvent that nothing fires. A listener
   attached that way reported **0 events** while the real game was working fine. Verify through
   world side effects — a label, a part position — not through a required module.
9. **The MCP bridge times out** on `execute_luau` calls longer than ~20 s. Long observation
   loops have to return early or be split.
10. **`require(SkyArm)` from `execute_luau` destroys the running rig.** The module rebuilds
    `Workspace.SkyArmRig` at require time, so requiring it in the test VM orphans the parts the
    live module is driving and leaves a second, undriven rig in its place. The symptom is an
    arm that has stopped moving for no reason — and the measurement that "found" it was the
    thing that broke it. Read the rig out of the world; never require it.
11. **The jaw opening was sized by hand for a 4-stud crate.** Against a real 6.72-stud cube the
    jaws closed *inside* it. Derived from `Mapping.cubeStuds()` now, along with the grip height,
    so both follow the mat scale.
12. **`SkyArm.setActiveBay` centred the crane on `Floor.Position`,** which bay 2's Void
    obstacle moves — it removes the floor over rows 0-1, leaving `Floor` centred on the
    surviving slab and parking the crane 8 studs off the bay. It reads the baked `Cell_0_1`
    anchor now, like everything else positional.
