# Bay 4 — Dark Room

**Status:** built and solved end to end in Studio. Untuned.
**Code:** `lebot_obby/ServerScriptService/HazardManager.lua` → `BUILDERS.DarkZone`
**Data:** `lebot_obby/ReplicatedStorage/BayData.lua` → `[4]`

---

## 1. The scenario

The door drops behind you and the lights go out. Ten screws are on the floor somewhere, and
you cannot see any of them.

A block on the operator's mat hangs a **lantern** from the ceiling above that cell. A screw is
**invisible unless its cell is lit** — so the bay is a conversation, not a walk: *"light column
two."* The operator is aiming a torch one cell at a time while you search the pool underneath
it.

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
| On entry | `Brightness` 1.20 → **0.15**, ambient near black; 0 lanterns, 0 screws visible |
| Block → lantern | lighting (1,1) and (2,0) → 2 lanterns lit, **2 screws visible** |
| Cell stays occupied | re-cycling a colour keeps the lantern lit |
| All cells lit | **10 / 10** screws visible |
| Collecting | walking each one → `POWER BOX - HOLD E`, prompt enabled |
| Driving the box | screwdriver turns → lights restored (1.20), `POWER BOX - ON` |
| Exit | door sinks to y = −5, `CanCollide = false` |
| Solve | `DarkZone SOLVED`, label `DARKZONE - CLEARED` |
| Console | 0 errors or warnings |

## 7. Open

- **Nothing is tuned.** Ten screws over twelve cells, a 2.5 s hold on the box, lantern range
  `CELL * 2.1`. All first guesses.
- **The cube budget is not enforced here.** Twelve cells can be lit at once in the debug
  editor, which trivialises the search. On the real rig the operator has a handful of cubes and
  has to *move* them, which is the intended texture — but nothing in the bay requires that.
  Worth deciding whether to cap lit cells.
- **No sound.** A search bay wants a click when a screw is found.
- **Screws are placed randomly each build**, so a reset reshuffles them. Deliberate, but it
  means a run cannot be rehearsed.
