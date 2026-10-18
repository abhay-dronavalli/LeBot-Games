# Bay 4 — Dark Room

**Status:** built and solved end to end in Studio. Untuned.
**Code:** `lebot_obby/ServerScriptService/HazardManager.lua` → `BUILDERS.DarkZone`
**Data:** `lebot_obby/ReplicatedStorage/BayData.lua` → `[4]`

---

## 1. The scenario

The door drops behind you and the lights go out. Ten screws are on the floor somewhere, and
you cannot see any of them.

A block on the operator's mat lights a **wall sconce** for that cell. A screw is **invisible
unless its cell is lit** — so the bay is a conversation, not a walk: *"light column two."*

The lamps are on the **walls**, not the ceiling, and the throw is deliberately wide: one lamp
bleeds across its neighbours, so a couple of blocks wash most of the room rather than picking
out twelve separate squares. Light raking in sideways also catches a screw lying on the floor,
which a lamp directly overhead flattens out and hides.

**Three cells are hotspots**, wired to a double fitting that throws much further. They are
visible even unlit by their amber neon trim, so the operator can read them from the spectator
view and choose: a hotspot reveals about four screws, any other cell about one. That is the
placement decision this bay is built around.

With all ten in, a **power box** on the right-hand wall at head height comes live. Hold **E**
to drive its screws: the screwdriver turns, the lights come back up, and the far door sinks
into the floor.

## 2. Why the block is a token

Same as the laser walk: `VirtualCrates` is set, so no crate is ever built. Nothing is carried
in and nothing is stood on. That matters here for a specific reason — this is a **search**, and
a 6.72-stud crate standing in a cell would block the floor you are trying to look at.

## 3. Why the screws are invisible rather than merely dark

The gate is explicit — `collect()` refuses unless `isLit(cell)` — rather than relying on the
room being dim enough that you cannot see them. Without it you could sweep the floor blind by
walking every cell, and the lanterns would be decoration. With it, light is the only way to
find anything, which is the whole bay.

## 3b. Driving the box swaps the lights over

The wall sconces go **out** and three ceiling panels come **up**, the global dim is lifted and
the far door sinks. The room going back to normal is the reward, and it reads as one event
rather than a door quietly opening somewhere.

## 4. The room is sealed

Four walls and a ceiling at **y = 14**, below the gantry rails at 18, so the arm still moves
above it. "Dark" has to come from being shut in; a tinted box you can see the warehouse
through does not read as a locked room.

## 5. Lighting is global, so it is saved and restored

`Lighting` is one service for the whole place. Entering dims `Ambient`, `OutdoorAmbient` and
`Brightness`; leaving, solving, resetting **and the run loop ending** all restore them. Leave
it dim and every other bay is dim too — including whatever the overseer is looking at.

## 6. Verified

| Check | Result |
|---|---|
| Builds | 12 lanterns, 12 bulbs, 10 screws, power box, 4 walls + ceiling, 2 doors |
| Builds | 12 sconces (3 amber hotspots, 9 plain), 3 ceiling panels |
| On entry | `Brightness` 1.20 → **0.00**, ambient near black; 0 lamps, 0 screws visible |
| Plain cell | one block → **1 screw** revealed |
| Hotspot cell | one block → **4 screws** revealed |
| Hotspots readable unlit | exactly 3 amber trims before anything is placed |
| All cells lit | **10 / 10** screws visible |
| Lights handover | wall lamps **0** lit, ceiling panels **3** on, `Brightness` back to 1.20 |
| Collecting | walking each one → `POWER BOX - HOLD E`, prompt enabled |
| Driving the box | screwdriver turns → lights restored (1.20), `POWER BOX - ON` |
| Exit | door sinks to y = −5, `CanCollide = false` |
| Solve | `DarkZone SOLVED`, label `DARKZONE - CLEARED` |
| Console | 0 errors or warnings |

## 7. Open

- **Reveal radius was tuned once already and may need it again.** At a 2-cell hotspot reach, a
  single block in a corner lit nine of twelve cells and showed 8 of the 10 screws — the whole
  bay solved by placing one cube anywhere. A plain lamp now reveals its own cell only and a
  hotspot the ring around it. Everything else — ten screws, a 2.5 s hold, the sconce ranges —
  is still a first guess.
- **The cube budget is not enforced here.** Twelve cells can be lit at once in the debug
  editor, which trivialises the search. On the real rig the operator has a handful of cubes and
  has to *move* them, which is the intended texture — but nothing in the bay requires that.
  Worth deciding whether to cap lit cells.
- **No sound.** A search bay wants a click when a screw is found.
- **Screws are placed randomly each build**, so a reset reshuffles them. Deliberate, but it
  means a run cannot be rehearsed.
