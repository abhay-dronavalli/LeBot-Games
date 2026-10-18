# The interface

One look across every screen: riveted iron plate, brass framing, amber gaslight text. The HUD
sits in the same palette as the hall it is drawn over, which is most of what makes it feel
built into the game rather than bolted on top of it.

Everything is Frames, UIStrokes and UIGradients — no images, no uploaded assets — so it
reproduces from source like the rest of the project.

---

## `ReplicatedStorage.UiTheme`

The shared look. Before it, each client script invented its own panel: three different dark
greys, three fonts, three ideas of what "danger red" meant. The HUD read like three separate
debug tools stacked on one screen, because that is exactly what it was.

```lua
local Ui = require(ReplicatedStorage.UiTheme)
local panel = Ui.panel({parent = gui, size = UDim2.fromOffset(460, 150), title = "BAY 1"})
Ui.text(panel.body, {text = "KILL THE BLADES", style = "task", tone = "danger"})
```

| Piece | What it gives you |
|---|---|
| `Ui.C` | The palette: `iron`, `brass`, `copper`, `patina`, `amber`, `parchment`, `faded`, `ghost`, `danger`, `warn`, `ok`, `info` |
| `Ui.F` | Fonts: `title` (Antique — Victorian signage), `task`/`number` (Oswald — condensed industrial), `body` (Merriweather), `label` (GothamBold) |
| `Ui.tone(name)` | Maps the server's own vocabulary (`tone = "danger"`) to a colour, in one place |
| `Ui.panel(opts)` | A riveted brass-framed panel. Returns `{frame, body, accent, setTitle, setTone}` |
| `Ui.text(parent, opts)` | A styled label. Styles: `title`, `task`, `hint`, `step`, `note`, `caption`, `label`, `number`, `big` |
| `Ui.crateIcon(parent, opts)` | One cube, or N stacked — a picture of the thing to place |
| `Ui.plate(part, opts)` | A **diegetic** brass plate: a SurfaceGui bolted to a part in the world |
| `Ui.rivet` / `Ui.rivetRow` / `Ui.rule` / `Ui.stroke` / `Ui.sheen` / `Ui.corner` | The detail pieces |

**Put content in `panel.body`, not `panel.frame`.** The body is already inset past the rivet
line; parenting straight to the frame puts your label underneath the rivets.

**Two guards exist because both traps were hit during the build:**

- `Ui.text` with an unknown style name used to take the whole client script down with
  `attempt to index nil with number`, blaming this file rather than the caller that misspelled
  it. It now warns, names the offender, and falls back to body text.
- `Ui.rivetRow` **refuses** to run on a frame with a `UIListLayout`/`UIGridLayout`. A rivet is a
  child Frame, and a child Frame in a laid-out container is a *list item* — called on the debug
  menu it marched rivets down the left edge as rows and shoved every control out of place.

---

## The player HUD — `ObjectiveHud.client.lua`

Three layers, deliberately separated, because they answer different questions. The old HUD had
only the first, so "that block was refused" appeared as a line of text inside a panel you had
already stopped reading. **Events have to move to be noticed.**

| Layer | Where | Lifetime | For |
|---|---|---|---|
| **Order board** | top centre | until the bay changes it | A standing statement of what this bay wants. Title, task, hint, a brass timer readout, a step checklist, a note. |
| **Toasts** | under the board | 4.5 s, stacked, max 3 | Something *just happened*: a block refused, a lever thrown. Newest on top, each self-expiring. |
| **Stamp** | screen centre | 2.4 s | The big one: `BAY 02 CLEARED`, `YOU DIED`. Scales down onto the screen like a stamp hitting paper. |

Toast text is uppercased on the way in. Refusal reasons arrive from two different server paths
in two different casings (`blades live` vs `BLADES LIVE - CANNOT DROP THERE`) and side by side
in one stack the mixed casing read like a bug.

A repeated toast refreshes the one already on top instead of stacking a duplicate — a guard
refusing the same cell twice is one event worth seeing, not two.

### Where each popup comes from

- **Toast** — `p.flash` on the objective payload, **edge-detected**. `flash` persists in every
  later push, so without the edge check the same refusal re-raises forever.
- **Toast / stamp, directly** — `Remotes.Toast:FireClient(player, text, tone, big)`. `big` makes
  it a stamp. This is the channel for an event that is not a change of objective.
- **`BAY nn CLEARED`** — the `solved` edge on the `DebugStatus` feed, not the objective payload,
  because a bay may clear its objective on the same frame it solves.
- **`YOU DIED`** — `Humanoid.Died`, purely client-side. The respawn was silent before, and in
  the dark room you genuinely could not tell you had died.

---

## Player 2 — `OverseerCam.client.lua`

Player 2's whole job is *put a cube on the mat at the right square*. That needs one coordinate
and one quantity, and it used to be spelled out nowhere: the old panel said "2 cells want a
block" and left the operator to find which two among a 4×3 of identically styled squares.

**The order card** is now the largest thing on their screen:

```
┌─ NEXT BLOCK ───────────┐
│  ▢   COL 1             │
│      ROW 0             │
│      ONE CUBE          │
│  ──────────────────    │
│  0 of 2 cells filled   │
└────────────────────────┘
```

- The **next** cell is the first wanted one not already filled, in the server's own
  `solveCells` order — so a routed bay like the laser walk follows its route rather than an
  order invented on the client.
- The cube count is read from `level` on the status feed, and drawn as **one cube or two
  stacked**, because a picture of the thing beats the number 2.
- An action bay (no cells called) says so plainly instead of showing a blank grid.

**The mat grid is now confirmation, not instruction.** Priority is deliberate and is the whole
point: *the next cell wins.* It is amber, thick-bordered, and breathes with a slow pulse —
motion is what the eye finds first among twelve identical squares. Placed cells are patina
green, other wanted cells are dim brass, and the runner's square is outlined in blue on top of
whatever it already is.

---

## In-world labels

There used to be six floating `BillboardGui` labels with `AlwaysOnTop = true`. Two things were
wrong with that, and both are fixed:

1. **They drew through walls.** The dark room's `POWER BOX` plate was legible from *outside*
   the sealed room, and labels from bays you were nowhere near floated over the scenery.
2. **One was pure duplication.** A bay banner hung at head height in the middle of every bay
   repeating the objective HUD word for word.

Now:

- `addLabel` builds a **brass plate** — dark iron, brass stroke, corner rivets, Antique type —
  with `AlwaysOnTop = false` so it occludes like anything else, and `MaxDistance = 55`.
  That distance is chosen, not arbitrary: close enough to read from anywhere inside the bay you
  are standing in, short enough that the **overseer**, parked 62 studs up, never sees them at
  all. Player 2 has the order card and the numbered floor pads for the same information, and in
  the top-down view these plates stacked on top of each other.
- The **bay banner moved onto the bay's own `Sign` part** — a physical sign that was already
  standing beside every bay doing nothing. It is a `SurfaceGui` on both faces (the sign's facing
  is baked geometry and guessing wrong points the plate into a wall); the returned proxy
  forwards `.Text` and `.TextColor3` to both, so callers write to it exactly like a TextLabel.
- The saw bay's floating **notice billboard is gone entirely**. It was a second copy of
  `flashText`, which already rides the next objective push and is now raised as a toast — the
  same information somewhere you are actually looking.

Labels that describe a *physical thing* (a lever, the power box, a ghost crate's target cell)
stayed, because they belong to the machine. Only the floating, duplicated and see-through-walls
ones went.

---

## Repo paths

| Repo path | Studio location |
|---|---|
| `ReplicatedStorage/UiTheme.lua` | `ReplicatedStorage.UiTheme` (ModuleScript) |
| `StarterPlayerScripts/ObjectiveHud.client.lua` | `StarterPlayer.StarterPlayerScripts.ObjectiveHud` |
| `StarterPlayerScripts/OverseerCam.client.lua` | `StarterPlayer.StarterPlayerScripts.OverseerCam` |
| `StarterPlayerScripts/DebugMenu.client.lua` | `StarterPlayer.StarterPlayerScripts.DebugMenu` |

`Remotes.Toast` is a `RemoteEvent`: `(text, tone, big)`.
