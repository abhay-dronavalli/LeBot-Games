# The environment — the steampunk hall

The course used to be boxed in by tight opaque walls because there was no backdrop. It now
sits on a raised iron platform inside one enormous industrial hall: brass and copper pipe
runs, boilers, gear trains, flywheels, pistons, turbines, laboratory benches with glass tanks
and tesla coils, warm gas-lamp light, soot and haze. The play space is bounded by **fences you
can see through**, so the hall is visible all the way round.

Everything here is **generated from source** by scripts in [`build/`](../build/). No Toolbox
models, no meshes, Roblox primitives only — so the whole environment reproduces from the repo
even though the `.rbxl` itself is gitignored.

---

## Folder layout

All scenery lives in one top-level folder, `Workspace.Backdrop`. **Nothing goes in
`Bay*/Obstacle`** — those folders are destroyed and rebuilt by `HazardManager` on every reset,
so anything parked there vanishes the first time a bay resets.

| Folder | What's in it | Built by |
|---|---|---|
| `Backdrop.Hall` | Hall floor, walls, wainscot, pilasters, arched windows, roof deck, skylight strip, iron roof arches | `build/backdrop_hall.lua` |
| `Backdrop.Lamps` | 16 hanging gas lamps (chain, brass body, neon glass, PointLight) | `build/backdrop_hall.lua` |
| `Backdrop.Platform` | Entrance + finale decks, platform skirt and brass nosing | `build/backdrop_containment.lua` |
| `Backdrop.Fences` | Posts, brass rails and mesh panels along the course and across both ends | `build/backdrop_props.lua` |
| `Backdrop.Pipes` | Wall pipe runs, risers, elbows, floor mains, valve wheels | `build/backdrop_props.lua` |
| `Backdrop.Machinery` | 6 machine clusters: boiler + firebox + stack, gear train, flywheel, pistons, turbine | `build/backdrop_props.lua` |
| `Backdrop.Labs` | Glass tanks, tesla coils, workbenches, scaffolding | `build/backdrop_props.lua` |
| `Backdrop.BayDressing` | Per-bay exteriors, the entrance gate and the finale furnace | `build/backdrop_props.lua` |

`Workspace.Warehouse` is untouched except for the Shell (below) and the catwalks, which are
**restyled in place** — material and colour only, never resized, because the bays' approach
geometry is measured against them.

---

## Re-running the generators

Each script deletes and recreates only its own sub-folders, so they are idempotent and can be
run in any order, as often as you like. Run them **in Edit mode** — geometry and lighting
created during a playtest is discarded when you stop.

Serve the repo to Studio, then run each from the command bar:

```
python tools/studio_sync.py 8767
```

```lua
local get = function(n)
    return loadstring(game:GetService("HttpService"):GetAsync("http://127.0.0.1:8767/" .. n))()
end
get("backdrop_lighting.lua")     -- Lighting, Atmosphere, Bloom, the colour grade
get("backdrop_hall.lua")         -- the hall shell, roof, skylight, lamps
get("backdrop_containment.lua")  -- Shell -> invisible collider, platform, spawn, racks
get("backdrop_props.lua")        -- fences, pipes, machinery, labs, bay dressing
```

`build/fit_shell.lua` and `build/scope_course.lua` still work and are unaffected: both rewrite
only Y and Z on the Shell parts and preserve `Position.X`, which is what lets the containment
walls be moved inward without breaking either.

---

## Containment: an invisible shell, a visible fence

The two jobs are deliberately split.

**`Workspace.Warehouse.Shell` is the collider.** Same four parts, same names (so `OverseerCam`,
`fit_shell.lua` and `scope_course.lua` all still find them), but now `Transparency = 1`,
`CanCollide = true`, `CanQuery = false`. The side walls moved in from x −7/39 to inner faces at
**x = −1 and x = 33**, one stud outside the bay floor edge.

> Before this, the Shell was `Transparency 0` **and `CanCollide false`** — opaque and
> non-blocking, the worst of both. There was no containment anywhere on the course: step off
> the floor edge and you fell out of the world, because the aisles, the entrance buffer and the
> finale buffer had no floor at all.

**`Backdrop.Fences` is the look.** Posts every 6 studs, two brass rails and a faint mesh panel,
all `CanCollide = false`. Two merged rail cylinders per side rather than a bar every stud: it
reads as a railing, the hall stays visible through it, and it costs ~66 parts instead of ~400.

Fence height is irrelevant to containment and nothing should ever depend on it — a player on a
2-cube stack (13.44) can jump ~7 studs higher. The 48-stud invisible Shell does the blocking.

### Why the camera used to be a wall

Roblox's default-camera Popper only treats a part as an occluder when it is **both** opaque
**and** collidable. The old Shell was opaque and *non*-collidable, so the camera never pulled
in — it slid straight inside a solid 48-stud wall and the near plane filled the screen with its
backface. Transparency 1 fixes it from the other side: an invisible part never occludes, so the
camera passes through and shows the hall, which is the entire point of building a backdrop.

---

## Readability: the course is lit, the hall is not

There is no per-part trickery here, just one piece of geometry doing the work.

A **skylight strip** (x −4..36) runs the length of the hall directly over the course. Its glass
has `CastShadow = false`, so the noon sun lands on the course floor. Everything else is under a
`CastShadow = true` roof deck and only gets `OutdoorAmbient` plus the gas lamps. The course
therefore reads brighter and crisper than the hall without touching a single material.

### Atmosphere density is the blue-cast dial

`Atmosphere.Density` scatters the **skybox** through the scene. The first pass ran at 0.36 and
rendered the whole warm brass hall cold blue, because the daytime sky was being smeared over
everything. It now sits at **0.18**, with `EnvironmentDiffuseScale` at 0.03 so image-based sky
lighting contributes almost nothing indoors, and `ColorShift_Top` warmed so the skylight shaft
reads as gaslight rather than noon. If the hall ever goes blue again, that is the dial.

---

## The Dark Room, and the lighting baseline

Bay 4 drives `Lighting.Ambient` / `OutdoorAmbient` / `Brightness` to near-black on entry and
restores them on exit. Verified: the room is still genuinely black with the new Atmosphere,
Bloom and `BackdropGrade` colour correction active, so **none of them needed to be added to
`setDark()`**.

**A real bug was found and fixed here.** `setDark()` captured its restore values in a local the
moment its builder ran — but a bay is reset *by rebuilding it*, so resetting bay 4 while the
room was dark captured the **dark** values as the baseline, and from then on every "restore"
restored to pitch black, for every bay, permanently.

The baseline is a property of the place, not of a moment. `build/backdrop_lighting.lua` now
stamps it onto Lighting as attributes and `HazardManager` reads them back:

```lua
Lighting:GetAttribute("BaselineAmbient")         -- Color3
Lighting:GetAttribute("BaselineOutdoorAmbient")  -- Color3
Lighting:GetAttribute("BaselineBrightness")      -- number
```

It falls back to the live values if the attributes are missing, so a place where the lighting
script has never been run still behaves as it did before.

**No light may leak into bay 4.** A `PointLight` has no shadows and shines straight through
walls. Every gas lamp keeps `Range <= 14` and hangs at x −16 / 48, far outside the room, and
**bay 4's own dressing uses Neon only** — emissive, but it illuminates nothing.

---

## The overseer's column

`OverseerCam` (**V**) parks at y = 62 × zoom (up to ~143) over the active bay and looks straight
down. Opaque scenery between **y 20 and 62** over the course footprint (**x −2..34, z −14..128**)
would blind player 2.

Two rules keep that column clear, and both are enforced by a check at the end of
`backdrop_props.lua`:

1. Anything tall lives outside x −2..34, or stays under y = 20.
2. Anything that must cross it is tagged **`OverseerHide`**, and `ghostWalls()` hides tagged
   parts in x-ray mode. The hall's roof deck, skylight panes and arch segments carry the tag.

That tag is the only change made to `OverseerCam.client.lua`: the generators own the tag, the
camera just honours it. Nothing is enumerated by name.

> **Machine cluster origins are load-bearing.** Each cluster's arm — gear train, flywheel,
> pistons, turbine — extends about **46 × scale studs inward** from its origin. The first pass
> put one at x = −44 and its turbine landed at x = −4, standing on the player's walkway. Every
> origin now clears the fence by 25+ studs at its own scale.

---

## Motion: tags, animated client-side

The server does **no** scenery animation. `BackdropFx.client.lua` reads CollectionService tags
and drives everything locally, so a few hundred decorative parts cost the server nothing and
replicate no CFrame stream.

| Tag | Effect | Attributes |
|---|---|---|
| `BackdropSpin` | Rotates about the part's X (a Cylinder's face axis) | `SpinSpeed` — rad/s, signed; default 0.6 |
| `BackdropFlicker` | Gutters transparency, and `PointLight.Brightness` if present | `FlickerFast` — jittery electric instead of slow gas |
| `BackdropSteam` | Grows a low-rate steam `ParticleEmitter` on the client | — |
| `BackdropEmber` | Grows a rising-ember emitter | — |

Current counts: 40 spinning, 36 flickering, 12 steam vents, 2 ember sources.

Three things worth knowing before editing it:

- **Spin rebuilds from a captured base CFrame** rather than accumulating onto the live one.
  Accumulating drifts and visibly skews the part after a few minutes of float error.
- **Flicker is biased upward, not centred.** Every emissive part here sits at `Transparency 0`,
  so a symmetric wobble spends half its time clamped at 0 and the lamp reads dead steady. The
  noise is shifted into 0..1 so the flicker is a *dimming from full*, which is what a flame does.
- **Everything is distance-throttled** at 190 studs. Per-frame cost tracks what is on screen,
  not how much scenery exists.

Tag changes are picked up live via `GetInstanceAddedSignal`, so re-running a generator while
standing in the place starts the new parts moving immediately.

---

## Rules for anything added later

- Every scenery part: `Anchored`, `CanCollide`/`CanQuery`/`CanTouch` **false**, `CastShadow`
  false. The only colliding layers are the invisible Shell and `Backdrop.Platform`'s decks.
- **Nothing under the course footprint** — the void shaft owns everything below bay 2.
- **Nothing inside the walk corridor** (x 0..32, y 0..10, z −10..121). `backdrop_props.lua`
  reports any part that breaks this; the only expected hit is the invisible ember anchor.
- Bays **1 and 4 stay sealed rooms**; dress their *exteriors* only, and never roof bay 1 — the
  crane has to reach in.
- Bay 3's cosmetic emitters are aligned to the real beam heights **1.6 / 4.4 / 7.2**. They are
  decoration; the lethal beams are built by `HazardManager`.
- Never `require()` `Config` from a build script — Studio's Edit datamodel caches modules for
  the session. Read it from source with the `configNumber()` pattern.
- Never `require()` `SkyArm` from a build script: it destroys the live rig.
