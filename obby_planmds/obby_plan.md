# Robo-Obby: Smart Warehouse Escape (Final Hackathon Plan)

**One-liner:** A Roblox worker trapped in a malfunctioning 4×27 automated warehouse and a physical robot-arm operator ("Master Gantry Controller") race against a lockdown clock. The operator places and stacks 14 color-coded ArUco blocks across a physical 4×3 grid to deploy industrial counter-crates into the active 4×3 Roblox warehouse bay, fighting back lasers, molten spills, and crushers while in-game hazards physically shake, lag, or freeze the real robot arm.

**Hardware:** SO-101 leader + follower pair (LeRobot), one webcam on an overhead tripod, a physical 4×3 grid mat + inventory tray, 14 cubes (2 each of 7 colors), a laptop.
**Time budget:** 24-36 hours.
**Priority:** Sky Arm + 4×3 Grid Sync → 9-Bay Warehouse Gauntlet (L1/L2 Stacking) → Procedural Clash VFX → Two-Way Arm Penalties.

**Who does what:** The robot teammate owns the robot, camera, vision and Python server (Parts III, roles A and B). The Roblox side (Parts I and II, roles C and D) is built entirely in Roblox Studio with all game logic in Luau. The two sides meet only at the protocol in Section 12.

---

> ## ⚠️ Read this before trusting the rest
>
> **This is the original plan, not a description of what exists.** The Roblox side has
> diverged from it. Parts I and II below are the *intent*; for what is actually built, see
> **[README.md](README.md)** (current state) and the per-scenario docs beside it.
>
> The divergences that matter:
>
>
> | Plan says | Reality |
> |---|---|
> | Nine bays | **Four.** `Config.NumBays = 4` — Saw, Void, LaserWalk, DarkZone. Bays 5-9 are parked past that index and their geometry is in `ServerStorage.OutOfScope`; nothing was deleted |
> | One block = one hazard, several hazards per bay (§4) | **One obstacle per 4×3 bay.** §4.1-4.2 are superseded — see README.md |
> | A bay is cleared by filling the right cells | True for **bay 2 only**. Bays 1, 3 and 4 are cleared by an **action** (`solveMode = "switches"` / `"action"`), with the crates as the means rather than the goal |
> | Colour-coded blocks gate the hazards | **No colour test exists anywhere in the solve path.** Any block satisfies any cell; `level` (a cube count) is the only requirement. Every colour requirement in this document is superseded |
> | `Bridge` feeds `cells` from the robot | **Built**, and verified end to end against a protocol-faithful mock — see [robot-link.md](robot-link.md). `DebugMode` is now the solo path rather than the only path |
> | 14 cubes, "peak blocks" up to 6 per bay | **14 cubes total**, colour irrelevant. Every bay is designed around 1 or 2, and three-high stacks do not exist |
> | Section 12 protocol | **Superseded** by the `robot-roblox-bridge` branch's `PROTOCOL.md` v1: the arm arrives as a stick figure of world points rather than joint angles, `blocks` replaces `cells`, `held` replaces `crane`, there is **no ArUco on the cubes**, and the effect names differ (`fog`, not `steam_lag`) — so §0's event-name row is superseded too |
>
> Part III (robot, vision, protocol) is otherwise unaffected — but read the live `hello` frame,
> not §12, for the wire format.

---

## 0. Decisions That Resolve Earlier Inconsistencies

These are fixed for the rest of this document.

| Topic | Decision |
|---|---|
| Message format | Section 12 (`t`, `seq`, `ts`, `arm`, `cells` with `level` and `ids`, `crane`). |
| Event names | `earthquake`, `steam_lag`, `mirror`, `molasses`, `freeze`, plus a `clear` event (new, see 12.2) to end any active effect. |
| Module names | The plan's names (`Bridge`, `StateStore`, `SkyArm`, `ActiveBayTracker`, `BlockSync`, `CrateEffects`, `HazardManager`, `Events`) plus `Config`, `CrateDefs`, `BayData`, `GameState`, `Hud`, `Fx`, `DebugMode`. |
| Run length | The old "90-120 second full run" is replaced by a configurable clock. Placeholder: Full Run 8:00, Demo Run 2:30. **Measure the operator's real placement and stacking time at T+17 and retune.** Placing about 30 blocks cannot fit in 2 minutes. |
| Bay advance | Position-based (`ActiveBayTracker`). No lever. Exit doors are always open, and a short reset window follows each bay change (10.4). |
| Demo Run bays | Bays 1, 2, 4, 7, 9, with `demo = false` hazards skipped. Matches the pitch in Section 16. |
| Pitch callouts | Match `BayData` exactly (Section 4). |
| Transport | WebSocket (`CreateWebStreamClient`) is the primary link at 20-30 Hz. HTTP polling is the fallback at 3-4 Hz. **Verify WebStreamClient works in Studio in the first 3 hours.** If not, ship on HTTP with tween smoothing. |
| Mock modes | Python `--mock` click-grid and the Roblox `DebugMode` cell editor both emit the same `cells` structure. |
| Kill switch | Robot side: a global hotkey that works even when Roblox has focus, plus a physical key. Roblox side: `F9` sends `clear`. Spacebar is not used for this, since it is Roblox's jump key. |
| Indexing | `col` 0-3 and `row` 0-2, 0-indexed everywhere. Row 0 is the row nearest the bay entrance. **Print the same labels on the physical mat and tape row 0 on the entrance edge.** |

---

## 1. Decisions Made (Hardware and Approach)

| Question | Default Chosen | Why |
|---|---|---|
| Arm | **SO-101 leader + follower** | Matches the leader/follower teleop setup. |
| How Roblox runs | **Studio Play mode on a laptop on the same LAN as the robot laptop** | Studio Play mode is the demo target. WebSocket (`CreateWebStreamClient`) for real-time two-way messaging if it works; HTTP polling (`GET /state`, `POST /event`) as fallback. |
| Physical Grid | **4×3 grid mat + taped side Inventory Tray** | Maps 1:1 to a sliding 4×3 "Active Bay" window along the 4×27 Roblox warehouse course. |
| Blocks | **14 small cubes (3-4 cm): 2 of each of the 7 colors (Red, Blue, Yellow, Green, Orange, Purple, Teal) with unique ArUco IDs on all 6 faces** | 1 block = Level 1 counter; stacking 2 blocks of the same color = Level 2 counter. Unique IDs per cube make 2-block stack detection via occlusion memory deterministic. |
| Roblox player input | **Standard keyboard and mouse** | The Roblox player walks and jumps normally. The operator drives the robot. |
| Build Order | **Sky Arm + 4×3 Grid Sync → 4×27 Bay Sliding Window → L1/L2 Block Counters & Clash VFX → Crane Lift → Two-Way Events** | Every step builds on the core loop and is demo-able at every checkpoint. |

---

# PART I: GAME DESIGN

## 2. Core Gameplay: The 4×27 Smart Warehouse Gauntlet

### 2.1 The "Sliding Window" Mechanic (4×3 × 9 Bays = 4×27 Map)
- The Roblox map is a straight industrial hallway **4 tiles wide by 27 tiles long**, divided into **9 Warehouse Bays (Bay 01 to Bay 09)**, each **4 columns × 3 rows**, separated by a thin safe-zone catwalk strip.
- **Active Bay Highlight:** The bay the Roblox player is currently inside lights up with a glowing `Neon` border and overhead floodlights. Other bays are dimmed.
- **The Giant Sky Arm:** A giant SO-101 hangs from ceiling gantry rails over the active bay and mirrors the real follower's joints live. When the player crosses into Bay N+1, the Sky Arm slides forward along the rails to hover over the new bay.
- **The Physical Reset Loop:** The physical 4×3 grid maps 1:1 to the active Roblox bay. The taped Inventory Tray beside the grid maps to nothing. As the player advances, the operator sweeps or re-picks blocks to counter the new bay's obstacles.
- **Player role while waiting:** the player scouts, calls out hazards as `(col, row)` plus color, and collects optional scrap tokens (Section 4.3). They read; the operator places.

### 2.2 The 7 Color-Coded Smart Crates (Level 1 vs. Level 2 Stacking)
You have **2 blocks of each color (14 blocks total)**. The effective limit is **2 per color per bay**, since the operator clears the table between bays.
- **Level 1 (`level = 1`):** one block in a `(col, row)` cell deploys a standard crate to counter a Level 1 hazard (marked `^`).
- **Level 2 (`level = 2`):** teleoperating the **second block of the same color** onto the first triggers an **Overcharged Double Crate**, countering Level 2 hazards (marked `^^`). A Level 2 crate also satisfies a Level 1 hazard of the same color.

| Color (×2) | Crate Metaphor | Level 1 Hazard & Counter (1 block) | Level 2 Hazard & Counter (2 stacked) |
|---|---|---|---|
| **Red** (`ID 10, 11`) | **Heavy Steel Cargo Crate** (Structural) | **Missing Floor Grate:** drops a steel pallet plate that clamps into the pit frame as a bridge. | **Tall Container Wall:** double-stacked cargo steps so the player can climb up. |
| **Blue** (`ID 12, 13`) | **Liquid Nitrogen Tank** (Cryo) | **Molten Spill / Acid Tile:** vents frost, turning the tile into a walkable `Ice` slab. | **Ruptured Flame Pipe Row:** dual-tank cryo-tower freezes all 4 tiles in the row and ices shut overhead fire jets. |
| **Yellow** (`ID 14, 15`) | **Mirror / Faraday Crate** (Laser Deflector) | **Waist-High Scanner Laser:** chrome deflector crate blocks the single low beam. | **Floor-to-Ceiling Plasma Wall:** a tall `ForceField` shutter door blocks stacked high and low lasers. |
| **Green** (`ID 16, 17`) | **Pneumatic Piston Crate** (Hydraulic Lifter) | **1-Story Bulkhead Ledge:** hydraulic launch pad bounces the player about 12 studs up. | **2-Story Mezzanine Blast Door:** twin-turbo pad launches the player about 25 studs up. |
| **Orange** (`ID 18, 19`) | **EMP Battery Cell** (Circuit Breaker) | **Single Floor Grinder / Saw:** grounding box sparks and powers down the trap in that cell. | **Synchronized Crusher Bay:** Tesla-coil crate pulses an orange ring, disabling *all* mechanical traps in the bay. |
| **Purple** (`ID 20, 21`) | **Mag-Lev Drone Pallet** (Anti-Gravity Crane) | **Open Smelter Vat:** spawns a hover-pallet; when the operator lifts the real Purple block, it carries the player through the air. | **Smelter Vat + Cross-Lasers:** spawns an enclosed Mag-Lev cage with side shields so the player isn't knocked off mid-flight. |
| **Teal** (`ID 22, 23`) | **Chrono Coolant Core** (System Override) | **Reverse Conveyor + Clock:** projects a speed strip (2× walk speed) and adds **+3 s** to the lockdown timer. | **Hyper-Conveyor + Closing Doors:** time-dilation dome freezes the countdown for **8 s** and slows all moving hazards in the bay. |

### 2.3 Pacing the 9 Bays
- **Bays 1-3 (Single-Block Tutorial):** Level 1 gaps, single lasers, single spills. Teaches callouts of `(col, row)` and color.
- **Bays 4-6 (Level 2 Stacking and Combos):** Plasma Walls (`Yellow ×2`), Mezzanine doors (`Green ×2`), full-row flame pipes (`Blue ×2`), and optional `Teal` pads that buy back clock time.
- **Bays 7-8 (High-Pressure Combo and Two-Way Sabotage):** crushers (`Orange`), lasers (`Yellow`), walls and pits (`Red`), and the full set of malfunctions.
- **Bay 9 (Smelter Finale, Crane Lift):** a 3-row open smelter pit. The operator places `Purple` (or stacks `Purple ×2` for the armored gondola) at Row 0, waits for the player to jump on, physically grabs and lifts the cube with the SO-101, and flies the player across the pit to the exit before time expires.

### 2.4 Two-Way Warehouse Malfunctions (Roblox → Real Arm)
Triggered when the player takes hazard damage, steps on a trap tile, hits an override panel, or at lockdown clock milestones.

| In-Game Event | Roblox Event Name | What Happens in Roblox | What Happens to the Real Follower Arm |
|---|---|---|---|
| **Seismic Crusher / Earthquake** | `earthquake` | Camera shake, ceiling dust, jittering platforms | Follower shakes (small sine wave + noise on pan/wrist, capped at ≤5 s) |
| **Steam Pipe Leak (Fog)** | `steam_lag` | Thick white steam fills the bay | Follower lags 300-800 ms behind the leader |
| **Wiring Short (Mirror World)** | `mirror` | UI glitches, sirens flash | Shoulder pan axis is inverted |
| **Hydraulic Leak (Molasses)** | `molasses` | Slow-motion visual tint | Follower commands are low-pass filtered (sluggish) |
| **Power Surge (Freeze)** | `freeze` | Sky Arm arcs with blue electricity and locks | Follower holds its position for 2-3 s |

---

## 3. Visuals, Assets and Procedural Clash Animations

### 3.1 Modular Warehouse Kit (Fast Studio Build)
- **1 Modular 4×3 Bay (duplicated 9×):** `DiamondPlate` floor tiles with yellow/black hazard borders, stencil bay numbers (`BAY 01`-`09`), ceiling I-beam gantry rails, decorative pallet racks on the side walls.
- **1 Base Smart Crate Prefab (duplicated 7×):** beveled metal cube (`CorrugatedMetal` + `Neon` core strips) tinted to each of the 7 colors with surface icons.

### 3.2 Procedural "Crate vs. Obstacle" Animations (`TweenService` + VFX)
Obstacles don't simply disappear; crates visibly overpower them.
1. **Sky Arm Laser Drop and Slam:** releasing a block fires a colored beam from the Sky Arm. The crate spawns 14 studs up, slams into the cell in `0.22 s` (`EasingStyle.Quad`), and emits a `Neon` shockwave ring (`8 studs` for L1, `18 studs` for L2).
2. **L1 → L2 Overcharge:** a second crate drops onto the first, an electric `Beam` arcs between them, and side armor plates or a `ForceField` dome tween out.
3. **Yellow vs. Laser Clash:** the emitter stays on, but its beam terminates against the crate's shield face with sparking `ParticleEmitters` and a pulsing `PointLight`. (If a Level 2 laser meets a Level 1 crate, the crate shakes and smokes, and the upper beam slices over it.)
4. **Blue vs. Molten Spill:** a frost ring expands across the tile (or the full row for L2), the hazard tweens from `Neon` Orange `(255, 80, 0)` to Cyan `(130, 225, 255)`, swaps to `Ice`, and fire particles scale to zero.
5. **Orange vs. Saws/Crushers:** an orange EMP ring pulses; blades tween spin to zero, tilt crooked, and emit sparks and black smoke.
6. **Green Hydraulic Launch:** stepping on the pad tweens the top plate up (`EasingStyle.Back`), bursts air particles, and applies an upward `AssemblyLinearVelocity` impulse.
7. **Purple Mag-Lev Crane Lift:** while `crane.active`, thruster particles flare beneath the pallet, a tractor beam connects it to the Sky Arm, and `AlignPosition` + `AlignOrientation` carry the player across the vat.

---

## 4. Bay Layouts (`BayData`)

> **⚠️ §4.1 and §4.2 are superseded.** They describe the original one-block-one-hazard
> model with several hazards per bay. The game now runs **one obstacle per bay**, and the live
> layout is in `lebot_obby/ReplicatedStorage/BayData.lua`, summarised in
> [README.md](README.md). What survived: the block budget (max 2 of any colour per bay) and
> the callout labels in §4.3. Kept for the reasoning and the hazard vocabulary, which the
> obstacle builders still draw on.

### 4.1 Lane-gate rule
Every hazard row has static barriers (pallet racks or walls) closing every column except one **gate lane**. The hazard sits in the gate lane, so the player must deal with it, and the callout is unambiguous ("Row 1, column 2, red").

`*` means the hazard spans the whole row. "Peak" is the most blocks the operator holds on the grid at once. Optional hazards are not required to pass.

| Bay | Row 0 | Row 1 | Row 2 | Peak blocks |
|---|---|---|---|---|
| 1 | none | Missing grate, col 1: **Red ×1** (`demo = false`) | none | 1 |
| 2 | none | Missing grate, col 2: **Red ×1** | Molten spill, col 2: **Blue ×1** | 2 |
| 3 | Bulkhead ledge, col 3: **Green ×1** | Saw, col 1: **Orange ×1** | Scanner laser, col 0: **Yellow ×1** | 3 |
| 4 | Teal bonus pad, col 0 (optional): **Teal ×1** | Molten spill, col 3: **Blue ×1** (`demo = false`) | Plasma wall, col 3: **Yellow ×2** | 3 |
| 5 | Mezzanine door, col 2: **Green ×2** | Flame pipe row, `*`: **Blue ×2** | Container wall, col 0: **Red ×2** | 6 |
| 6 | Saw, col 3: **Orange ×1** | Laser, col 1: **Yellow ×1**; Teal ×2 pad, col 0 (optional) | Container wall, col 2: **Red ×2** | 4-6 |
| 7 | Saw, col 1: **Orange ×1** | Crusher row, `*`: **Orange ×2** or time it by hand | Laser, col 2: **Yellow ×1** (`demo = false`) | 3 |
| 8 | Plasma wall, col 3: **Yellow ×2** | Crusher row, `*`: **Orange ×2** | Container wall, col 2: **Red ×2** | 6 |
| 9 | Smelter vat (all 3 rows): **Purple ×1 or ×2**, held and lifted | continues | continues | 1-2 |

**Notes**
- **Block budget:** every bay needs at most 2 blocks of any color.
- **Crusher rule:** a Crusher cycles with a 1.2 s safe window, so a bold player can time it by hand (lethal on a mistime). Orange L2 stops it and also clears every Saw in the bay. In Bay 7, Orange ×2 clears saw and crusher at once; Orange ×1 clears only the saw.
- **Demo flags:** hazards marked `demo = false` are skipped in Demo Run so the demo needs few placements.
- **Override panels (stretch):** in Bays 7-8, an optional panel on a side ledge skips one hazard row but triggers a malfunction. This is the "emergency override" from the original plan.

### 4.2 Hazard types and what counters them

| HazardType | Level | Countered by |
|---|---|---|
| `Grate` | 1 | Red L1 (or L2) in the cell |
| `ContainerWall` | 2 | Red L2 in the cell |
| `Spill` | 1 | Blue L1 (or L2) in the cell |
| `FlamePipeRow` | 2 | Blue L2 anywhere in the row |
| `Laser` | 1 | Yellow L1 (or L2) in the cell |
| `PlasmaWall` | 2 | Yellow L2 in the cell |
| `Ledge` | 1 | Green L1 (or L2) in the cell |
| `Mezzanine` | 2 | Green L2 in the cell |
| `Saw` | 1 | Orange L1 in the cell, or Orange L2 anywhere in the bay |
| `Crusher` | 2 | Orange L2 anywhere in the bay (or hand-timing) |
| `Vat` | 1 or 2 | Purple held and lifted (L2 adds the shielded cage) |
| `Conveyor` | n/a | Teal (bonus only, never required) |

### 4.3 Per-bay extras
- **Callout labels:** each hazard has a world-space label showing `(col,row)`, the color swatch, and chevrons.
- **Scrap tokens:** optional collectibles on safe catwalk spots and side ledges, worth score. They give a waiting player something to do.

---

## 5. Crate Effects and Hazard Resolution

### 5.1 Data-driven definition (`CrateDefs`)
```lua
return {
  red    = { name = "Steel Cargo Crate", L1 = "GrateBridge",   L2 = "ContainerStairs" },
  blue   = { name = "Cryo Tank",         L1 = "FreezeTile",    L2 = "FreezeRow" },
  yellow = { name = "Mirror Crate",      L1 = "BlockLaserLow", L2 = "PlasmaShutter" },
  green  = { name = "Piston Crate",      L1 = "LaunchPad12",   L2 = "LaunchPad25" },
  orange = { name = "EMP Cell",          L1 = "KillOneTrap",   L2 = "KillAllTrapsInBay" },
  purple = { name = "Mag-Lev Pallet",    L1 = "HoverPallet",   L2 = "HoverCage" },
  teal   = { name = "Chrono Core",       L1 = "TimePlus3",     L2 = "FreezeClock8" },
}
```

### 5.2 Resolution logic (run on every state update)
1. Receive `cells`. Diff against the last applied snapshot by `(col, row, color, level)`.
2. **Added** crate: wait 0.2 s to confirm, spawn the prefab with the drop-and-slam animation, apply the effect `CrateDefs[color]["L"..level]`.
3. **Removed** crate: wait 0.4 s before undoing the effect, so detection flicker doesn't cause popping or deaths. Then play a retract animation.
4. **Level 1 → 2:** play the Overcharge transformation and swap the L1 effect for the L2 effect.
5. A hazard is **countered** when an active effect matches its table row in 4.2.
6. **Mismatch feedback:** a wrong color shows a red X flash over the cell. An L1 crate against an L2 hazard shakes and smokes and does not counter it.

### 5.3 Purple crane lift (Bay 9)
- While `crane.active`, the hover pallet follows `(x, y, z)` through `AlignPosition` + `AlignOrientation` (server network owner), and the character's root part is welded or constrained to the pallet.
- **Safety:** if `crane.active` drops to false while the player is on the pallet, the pallet lowers gently (about 1.5 s) to the nearest safe platform. Over the vat, give a 2 s hover first so the operator can re-grab.
- Purple ×2 adds side shields so cross-lasers can't knock the player off.
- All malfunctions are suppressed while `crane.active`.
- `crane.x/y/z` are table-frame positions. Proposed units: **cm, origin at the corner of cell (0,0), x along columns, y along rows, z up**. Roblox converts with `Config.StudsPerCm`. **Confirm units with the robot teammate.**

---

## 6. Run Structure, Scoring, Modes

**State machine (`GameState`):** `Lobby → Briefing → Running → BayTransition → Running ... → Victory | Lockdown`. Only `GameState` changes state; everything else listens.

| Mode | Contents | Clock (placeholder) |
|---|---|---|
| **Full Run** | Bays 1-9, +3 s per Teal L1, 8 s freeze per Teal L2 | 8:00 |
| **Demo Run** | Bays 1, 2, 4, 7, 9, skipping `demo = false` hazards, skipping the briefing | 2:30 |
| **Practice** | Pick any bay, no clock, no malfunctions | none |

- **Death:** respawn at the bay checkpoint, hazards stay as the operator left them, **+10 s** clock penalty.
- **Lockdown (fail):** clock hits zero, doors seal, lights go red, "LOCKDOWN COMPLETE" with the bay reached, one-key restart.
- **Victory:** Bay 9 exit opens, confetti, score screen.
- **Score:** time remaining (largest), scrap tokens, clean bays (no deaths), L2 counters used, malfunctions survived.
- **Tuning:** retune all clock numbers in `Config` after measuring the operator's real placement and stacking time. Target: a normal run finishes with 20-30 s to spare.

---

# PART II: ROBLOX STUDIO IMPLEMENTATION

## 7. Explorer Layout and Coordinates

```
Workspace
  Warehouse
    Bay01 ... Bay09      (Model per bay, built from one prefab)
      Floor, Walls, HazardAnchors, CrateAnchors, ExitDoor, Checkpoint
    Catwalks
    SkyRails
  SkyArm
  SpawnLocation
ReplicatedStorage
  Config, CrateDefs, BayData, Remotes (RemoteEvents), Prefabs (crates, VFX)
ServerScriptService
  Bridge, StateStore, GameState, ActiveBayTracker, BlockSync, HazardManager,
  CrateEffects, SkyArm, Events, DebugMode
StarterPlayer > StarterPlayerScripts
  Hud, Fx
StarterGui
  Hud (ScreenGui)
```

### Cell grid (get this right once)
- One cell is **8×8 studs**. A bay is **4 columns (X) by 3 rows (Z)**, 32×24 studs, with a 6-stud catwalk between bays. Bay `N` starts at `Z = (N-1) * 30`. Store these in `Config`.
- Each bay prefab holds 12 invisible `Part` anchors named `Cell_c_r` (for example `Cell_2_1`).
- One helper, `BlockSync.cellToWorld(bayModel, col, row)`, returns a `CFrame`. **Nothing else hard-codes world positions.**

### Tags and attributes
Hazard parts get the `CollectionService` tag `Hazard` and attributes `HazardType`, `Level`, `Col`, `Row`, `Demo` (boolean). `HazardManager` finds them with `GetTagged("Hazard")` and filters to the active bay. A hazard is added by dragging a part into a bay and setting attributes.

### Module responsibilities

| Module | Where | Does |
|---|---|---|
| `Config` | ReplicatedStorage | All tunables: clocks, penalties, studs per cell, poll rate, sound IDs, intensity |
| `CrateDefs` | ReplicatedStorage | The 7 crate definitions (5.1) |
| `BayData` | ReplicatedStorage | Layouts from Section 4 |
| `Bridge` | ServerScriptService | WebSocket client with HTTP polling fallback, sends events, staleness |
| `StateStore` | ServerScriptService | Latest state, Heartbeat interpolation of the arm and crane |
| `GameState` | ServerScriptService | State machine, clock, score, modes |
| `ActiveBayTracker` | ServerScriptService | Player Z position → current bay (1-9) |
| `BlockSync` | ServerScriptService | Diffs `cells`, spawns and removes crates, `cellToWorld`, Purple crane |
| `CrateEffects` | ServerScriptService | Slams, shockwaves, clashes, effect application |
| `HazardManager` | ServerScriptService | Spawns and drives hazards, evaluates countered state |
| `SkyArm` | ServerScriptService | Mirrors `arm` joints, slides along rails between bays |
| `Events` | ServerScriptService | Malfunction scheduling and sending (Section 9) |
| `DebugMode` | ServerScriptService | Fake data source (Section 10) |
| `Hud`, `Fx` | StarterPlayerScripts | UI and client-side feel |

**Server owns truth, client owns feel.** The server decides which crates exist and whether the player lives. Clients render UI, shake, and local effects, notified by RemoteEvents.

### Transport rules
- `Bridge` is the only module that touches `HttpService` or `WebStreamClient`.
- **WebSocket path:** receive `state` messages at 20-30 Hz and send `event` and `bay` messages.
- **HTTP fallback:** poll at 3-4 Hz (roughly 200 requests per minute). Roblox limits outbound requests per server (I recall about 500 per minute, so verify) so never exceed the limit. Always tween the Sky Arm toward the latest reading (about 0.25 s) so it looks smooth at low rates.
- **Staleness:** if `ts` is older than 2 s, show "CONTROLLER OFFLINE", freeze the Sky Arm in a safe pose, and send no malfunction events.

---

## 8. HUD, Camera, Audio

### HUD
- **Lockdown clock** (top center, large, red under 30 s) and a **bay indicator** ("BAY 04 / 09") with a 9-segment progress bar.
- **Ghost minimap:** a 4×3 grid showing hazard icons by cell, their required color and level, and **live crate state** from the robot. This is the shared truth the player and operator check against. Pair every color with a letter or shape (R, B, Y, G, O, P, T) so it is readable without color.
- **Callout cards** listing hazards as text ("ROW 1, COL 2 - RED ×1").
- **Malfunction banner** with a remaining-time bar, and a **controller status** light.
- Use large text. People read it from across a demo table.

### Camera
Third-person follow camera, elevated, with a fixed angle per bay so every hazard is visible. Use `CameraType = Scriptable` and tween between bay angles on bay change. An optional spectator key (`V`) shows the whole active bay from above for judges. Add it last.

### Audio and visual clarity
- Distinct sounds: crate slam, hazard countered, lockdown tick under 30 s, bay-clear sting, malfunction siren. Keep sound IDs in `Config`.
- Screen shake scales with level (small for L1, large for L2).
- Hazards use hazard-orange and black stripes; safe zones use cool blue lighting.
- Crate colors match the physical block colors exactly.

---

## 9. Malfunction Rules (Events)

Roblox decides when and which, then sends `{"t":"event","name":...,"intensity":...,"duration":...}`. The robot side decides how the arm responds. The rules protect the real operator:

1. **Telegraph first:** a 1.5 s in-game warning (siren plus banner) before sending the event.
2. **One at a time:** never overlap.
3. **Cooldown:** at least 10 s between the end of one and the start of the next.
4. **No malfunctions** while `crane.active`, during the Bay 9 lift, or in the 3 s after a bay change.
5. **Always show remaining time** on the HUD so the operator knows when it ends.
6. **Earned, not random:** triggered by hazard damage, trap tiles, override panels, or clock milestones. Random chance may supplement, but the player should feel they caused it.
7. **Kill switch:** `F9` in Roblox sends `{"t":"event","name":"clear"}` and ends any effect at once.
8. **Intensity setting:** `Config.MalfunctionIntensity` from 0 to 1 scales frequency; 0 disables them.

**Severity ramp:** none in Bays 1-3, `earthquake` only in Bays 4-5, three types in Bays 6-7, all five in Bay 8. Bay 9 has none while lifting.

---

## 10. Debug Mode and Build Order

### 10.1 Debug Mode (build this first)
You will spend most of the weekend without the robot.
- `Config.DebugMode = true` swaps `Bridge`'s data source for a local fake, emitting the same `state` structure as Section 12.
- **Cell editor:** an on-screen 4×3 grid. Click a cell to cycle color, shift-click to toggle `level` 1 or 2. It writes the same `cells` list the robot sends.
- **Hotkeys:** `1`-`9` jump to a bay, `N` next bay, `T` add 10 s, `K` kill active malfunction, `H` toggle a held Purple crane, `M` trigger a chosen malfunction, `R` reset the run.
- **Mock arm:** a script that drives the six joints with a gentle sine wave so the Sky Arm can be built without the real feed.
- **Failure injection:** hotkeys to simulate flicker (cells vanish for 0.5 s) and stale data, to test the grace delays and the offline banner.

### 10.2 Roblox build order (each step demo-able)

| Step | Deliverable | Done when |
|---|---|---|
| 1 | One `Bay` prefab with 12 cell anchors and `cellToWorld` | You can print the world position of any `(col,row)` |
| 2 | `DebugMode` cell editor and fake `Bridge` source | Clicking cells produces a `cells` diff |
| 3 | `BlockSync` with slam animation and L1/L2 spawn | Clicking a cell drops a colored crate |
| 4 | Bay 2 playable: Red grate, Blue spill, clock, checkpoint | You can finish Bay 2 alone |
| 5 | The other crate effects and hazards, one color at a time | Each color counters its hazard |
| 6 | Bays 1-9 from `BayData`, `ActiveBayTracker`, camera tween | A full run is possible in Debug Mode |
| 7 | `Hud`, ghost minimap, callouts, scoring, win and fail screens | Someone else can play without explanation |
| 8 | `SkyArm` with the mock arm, then the live feed | The giant arm follows a data source |
| 9 | Real `Bridge` (WebSocket, HTTP fallback), staleness handling | Works against the robot teammate's server |
| 10 | `Events` with fairness rules and kill switch | A malfunction telegraphs, fires, ends |
| 11 | Purple crane lift and Bay 9 | Finale works with real `crane` data |
| 12 | Demo Run, audio pass, polish | A full Demo Run is reliable |

**Progress against this order** (detail in [README.md](README.md)): steps 1-3 done; step 5
reinterpreted as one obstacle per bay and done for all nine; step 6 partly — the bays exist
but `ActiveBayTracker` does not, so only Bay 1 is wired; step 7 partly — an objective HUD with
a live timer exists, scoring and win/fail screens do not; step 8 done against the mock feed.
Steps 4, 9, 10, 11 and 12 not started.

**Cut order if time is tight:** spectator camera, scrap tokens, override panels, Teal side objectives, Bays 3 and 6, malfunction variety (keep `earthquake` and `freeze`), L2 effects for the lowest-impact colors. **Never cut** Debug Mode, the HUD, or the Demo Run.

---

# PART III: ROBOT, VISION AND INTEGRATION

## 11. Architecture and 4×3 Grid Tracking (`server/world.py`)

Because the play area is a discrete **4×3 grid** and each of the 14 blocks has its own ArUco ID (`10` to `23`):

1. **Cell assignment:** homography maps the play mat into 4 columns (`col` 0-3) and 3 rows (`row` 0-2), plus the outside `tray` zone.
2. **Grid-cell occlusion memory:**
   - When `Yellow_A` (`ID 14`) is placed in cell `(2, 1)`, the camera sees `ID 14` at `(2, 1)` → `level = 1`.
   - When the operator stacks `Yellow_B` (`ID 15`) on top of `Yellow_A`, the camera sees `ID 15` in `(2, 1)` while `ID 14` is occluded underneath.
   - Because `ID 14` was last tracked in `(2, 1)` and hasn't appeared elsewhere or in the tray, `world.py` marks the cell `color = "yellow"`, `level = 2`.
   - When `ID 15` is lifted off, `ID 14` becomes visible again and the cell reverts to `level = 1`.
3. **Hybrid snap vs. continuous crane tracking:**
   - **Placed blocks (`crane.active = false`):** snap to the center of `(col, row)` so platforms never jitter.
   - **Held Purple block (`crane.active = true`):** when a Purple block (`ID 20` or `21`) disappears near the closed gripper tip, switch to continuous 3D forward kinematics `(x, y, z)` so the operator can smoothly crane-lift the player.

## 12. Message Protocol (JSON)

### 12.1 Python → Roblox (about 20-30 Hz over WebSocket, 3-4 Hz over HTTP)
```json
{
  "t": "state",
  "seq": 1042,
  "ts": 1760700000.12,
  "arm": {
    "shoulder_pan": 12.1,
    "shoulder_lift": -40.3,
    "elbow_flex": 55.0,
    "wrist_flex": 20.2,
    "wrist_roll": -3.0,
    "gripper": 34.0
  },
  "cells": [
    {"col": 1, "row": 0, "color": "red",    "level": 1, "ids": [10]},
    {"col": 2, "row": 1, "color": "yellow", "level": 2, "ids": [14, 15]}
  ],
  "crane": {
    "active": true,
    "color": "purple",
    "level": 1,
    "x": 21.5,
    "y": 30.2,
    "z": 8.1
  }
}
```
- `cells` contains only occupied cells of the active 4×3 grid.
- `crane` is `{"active": false}` when no block is being lifted.
- Joint units (degrees or radians) must be fixed in `Config`. **Confirm with the robot teammate.**

### 12.2 Roblox → Python
```json
{"t": "event", "name": "earthquake", "intensity": 0.7, "duration": 4}
{"t": "event", "name": "clear"}
{"t": "bay", "index": 4, "time_left": 72.5}
```
- `name` is one of `earthquake`, `steam_lag`, `mirror`, `molasses`, `freeze`, or `clear` (ends any active effect; new in this version, so the robot side must handle it).
- `bay` is sent on every bay change.

### 12.3 HTTP fallback
`GET /state` returns the latest `state` message. `POST /event` accepts the `event` and `bay` messages.

---

## 13. Suggested Repo Layout

```
robo-obby/
  server/
    main.py                        # starts robot, vision, ws_server; --mock flag
    robot_loop.py                  # LeRobot SO-101 teleop + safety clamps + effects
    effects.py                     # earthquake, steam_lag, mirror, molasses, freeze, clear
    kinematics.py                  # SO-101 planar FK for Sky Arm tip and Purple crane lift
    vision.py                      # 4-corner ArUco homography + 4x3 grid cell mapping
    world.py                       # 14-block tracker, cell occlusion stacking (L1/L2)
    ws_server.py                   # asyncio WebSocket broadcast + HTTP fallback
    config.yaml                    # ports, IDs 10-23 -> 7 colors, safe joint limits
    calibrate_robot_to_table.py    # 4-point gripper-to-grid calibration
    debug_view.py                  # OpenCV HUD: 4x3 grid, L1/L2 stacks, FK dot
  roblox/                          # text copies of every Luau script, for judges
    Config.lua  CrateDefs.lua  BayData.lua
    Bridge.lua  StateStore.lua  GameState.lua  ActiveBayTracker.lua
    BlockSync.lua  CrateEffects.lua  HazardManager.lua  SkyArm.lua
    Events.lua  DebugMode.lua  Hud.lua  Fx.lua
  assets/markers/                  # printable ArUco sheets (IDs 0-3 corners, 10-23 blocks)
  PROTOCOL.md                      # copy of Section 12
  README.md
```
Roblox saves places as binary `.rbxl` files that don't diff or merge. Copy each script's text into `roblox/` by hand and have one person own the place file.

## 14. Team Split (3-4 People; for 2 People, Merge A+B and C+D)

| Role | Owns |
|---|---|
| **A. Robot & Teleop** | LeRobot SO-101 setup, `robot_loop.py`, two-way physical effects (earthquake, lag, mirror, molasses, freeze, clear), safety clamps, global kill hotkey, FK math, robot-to-grid calibration. |
| **B. Vision & Grid World** | Camera mount, 4×3 grid mat and ArUco cubes (IDs 10-23), per-frame homography, cell occlusion stacking (L1 vs L2), OpenCV debug HUD, `--mock` click-grid simulator. |
| **C. Roblox Core & Systems** | `Bridge`, `StateStore`, `GameState`, `SkyArm`, `ActiveBayTracker`, `BlockSync`, `Events`, `DebugMode`, and the `AlignPosition` physics for the Purple crane lift. |
| **D. Roblox Warehouse & VFX** | The 4×27 shell (9 modular bays), 7 crate prefabs, hazard prefabs and `BayData`, `CrateEffects`, `HazardManager`, `Hud`, `Fx`, audio, demo script, and backup video. |

## 15. Timeline (about 30 Working Hours)

| Window | Goal | Milestone (demo-able) |
|---|---|---|
| **T+0-3: De-risk** | A: SO-101 teleop reading joints. B: camera mounted, 4×3 homography and 14 block IDs detected. C: Studio ↔ Python `--mock` link working (WebSocket if available, else HTTP), `AlignPosition` platform test. D: one modular 4×3 bay, tape ArUco markers on all 14 cubes. | Every hardware and physics risk proven in isolation. **WebStreamClient verified or ruled out.** |
| **T+3-7: Live Grid + Sky Arm** | Connect real vision and arm to Roblox. The Sky Arm mirrors real joints and slides across bays; placing cubes spawns crates in the active bay. | M1: real arm + 4×3 grid spawns crates in the active bay. |
| **T+7-13: L1/L2 Stacking and Hazards** | Occlusion stacking (L1 vs L2) in `world.py`. All 7 block powers across Bays 1-8, plus the Purple crane lift in Bay 9. | M2: stacking 2 cubes upgrades crates to L2; the crane lift clears Bay 9. |
| **T+13-17: Clash VFX and Timer** | `CrateEffects` (slams, shockwaves, laser blocks, cryo freeze, EMP sparks) and the lockdown clock (Teal adds time). **At the end, time the operator's real placement and stacking and retune `Config` clocks.** | M3: crates visibly fight and overpower hazards. |
| **T+17-21: Two-Way Malfunctions** | Wire hazard hits and override panels to `effects.py` with strict servo caps and the kill switch. | M4: hitting a laser in Roblox shakes the physical arm. |
| **T+21-25: Full 9-Bay Balancing** | Tune layouts so a normal Full Run fits the clock with 20-30 s spare. Polish the OpenCV HUD for the second monitor. | M5: full Gauntlet playable start to finish. |
| **T+25-End: Freeze and Polish** | Feature freeze 6 hours before judging. Sound, lighting, UI polish, backup demo video, rehearse the pitch 3×. | Demo ready. |

## 16. Demo Setup and 3-Minute Pitch

**Physical layout:** SO-101 leader + follower, the 4×3 mat, and 14 cubes front and center. The large screen shows Roblox Studio (facing both the judges and the operator). A second monitor shows the OpenCV Vision HUD (4×3 grid, detected colors, L1/L2 badges). Run **Demo Run mode** (bays 1, 2, 4, 7, 9).

- **0:00-0:25, Hook and Sky Arm:** "What if escaping a video game required a real-world robot operator?" Move the leader arm; the giant Sky Arm on the warehouse ceiling mirrors it live. Walk the player from Bay 1 into Bay 2 and show the Sky Arm slide to the next zone.
- **0:25-1:05, Level 1 counters (Bay 2):** the clock starts. Player calls out: "Missing floor grate at Col 2, Row 1, need Red! Molten spill at Col 2, Row 2, need Blue!" The operator places single Red and Blue blocks. The steel bridge slams down and the cryo tank freezes the spill into ice.
- **1:05-1:50, Level 2 stacking and clash VFX (Bay 4):** the player reaches a Level 2 Plasma Wall: "Level 2 plasma wall at Col 3, Row 2, stack two Yellows!" The operator places one Yellow (the crate shakes as the beam slices over it), then stacks a second on top. The OpenCV HUD flips to L2, the crate overcharges with an arc, and the ForceField shutter blocks the wall. The operator drops a Teal block for +3 s on the clock.
- **1:50-2:25, Two-way sabotage (Bay 7):** the player clips the spinning saw. A siren telegraphs, then an earthquake hits and the follower arm visibly shakes while the operator places an Orange EMP block to fry the saw.
- **2:25-3:00, Crane lift finale (Bay 9):** at the smelter vat the operator places a Purple block at Row 0, the player jumps onto the Mag-Lev pallet, and the operator lifts the Purple cube with the arm, flying the player across the pit to the exit before the timer hits zero.

**Always have a backup video** of a full successful run and know the kill switches (`F9` in Roblox, global hotkey on the robot laptop).

## 17. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| 2-block stack topples during teleop | Use flat, non-glossy 3-4 cm cubes. Add a 3-5 s "stack grace window" in `world.py`, or let two same-color blocks touching in the same cell also count as Level 2. |
| Arm occludes camera while placing | `world.py` locks a cell's state for 0.5 s when the FK gripper tip is over that cell. Roblox adds its own 0.2 s confirm and 0.4 s removal delay (5.2). Tune the two together. |
| Platform doesn't carry player during crane lift | Unanchored part driven by `AlignPosition` + `AlignOrientation` (server network owner), with the character's root part constrained to the pallet while `crane.active`. |
| Shaking damages servos or knocks over stacks | Cap earthquake amplitude to a few degrees and duration to ≤5 s, enforce `max_relative_target`, global kill hotkey, and `F9` `clear`. |
| Tripod bumped during demo | Recompute the grid homography every frame from corner markers (IDs 0-3). |
| WebStreamClient doesn't work in Studio | Verify in the first 3 hours; HTTP polling with tween smoothing is the fallback. |
| Clocks too short for real placement speed | Measure at T+13-17 and retune `Config`. |
| Detection flicker causes unfair deaths | Confirm and removal delays, minimap shows live crate state. |
| Row/column confusion between player and operator | Same labels printed on the mat and shown on the HUD, row 0 at the entrance edge. |
| Feed drops mid-run | Staleness banner, Sky Arm freezes safely, no malfunctions fire, crane lowers gently. |

## 18. Playtest Checklist

- [ ] Every hazard in every bay is solvable with at most 2 blocks of each color.
- [ ] Every gate lane is the only route (the player cannot jump around a hazard).
- [ ] A new player can read the HUD and understand Bay 2 without help.
- [ ] A removed block takes 0.4 s to unapply, with no flicker deaths.
- [ ] The offline banner appears within 2 s of the feed stopping.
- [ ] No malfunction fires while `crane.active` or in the first 3 s of a bay.
- [ ] `F9` and the robot-side hotkey both end a malfunction immediately.
- [ ] Demo Run completes inside its clock with a normal operator.
- [ ] Colors are distinguishable by letter or shape, not only hue.
- [ ] Studio's Output window shows no errors during a full run.
- [ ] The pitch callouts match `BayData` exactly.

## 19. Prize Notes

The Roblox challenge requires the project to be built within Roblox Studio with core logic in Luau. Crate logic, hazards, the clock, malfunctions and the bridge are all Luau. Keep Python and Luau in separate folders and keep text copies of the Luau scripts in `roblox/` so judges reading GitHub can see the game logic. Describe any reused earlier work (Muse, gaze, LeRobot grid) as reusable components and make the new weekend work obvious. Check SwampHacks' rules on pre-existing code.

## 20. Open Items to Confirm

1. Units for joint angles (degrees or radians) and for `crane.x/y/z` (proposed cm, origin at cell (0,0) corner).
2. Whether the robot server accepts the `clear` event.
3. Whether `CreateWebStreamClient` works in Studio on your account (verify in the first 3 hours).
4. The operator's real time to place and to stack a block, to set the clocks.
5. Which physical edge of the mat is row 0.

## 21. References

- Roblox `WebStreamClient`: https://create.roblox.com/docs/reference/engine/classes/WebStreamClient
- Roblox in-experience HTTP limits: https://create.roblox.com/docs/cloud-services/http-service
- LeRobot robot API (SO101Follower / SO101Leader): https://huggingface.co/docs/lerobot/main/api/robots