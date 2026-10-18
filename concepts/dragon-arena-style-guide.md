# Dragon Arena: visual style guide

Read this before you build or change anything visual in the Dragon Arena mode. It sets the
look. It does not set gameplay numbers (round length, damage, power-up spawn rate); those are
the designer's call.

**The mode.** One operator drives the real SO-101 arm with the leader arm. In Roblox, that arm
is a giant dragon in a volcanic arena. The dragon attacks up to 12 players by slamming its head
into the ground, sweeping across the floor, and opening its jaw (the gripper) to breathe fire.
Players dodge, and grab power-ups that send real effects to the arm (shake, slow, inverted
controls, and the rest in `PROTOCOL.md`). Players still alive when the timer ends win. If
nobody is left, the dragon wins.

This guide builds on `PROTOCOL.md`, `roblox/README.md` and `plan.md` (Mode C, 1v1 Arena).
Read those for the data. This file covers how it looks.

---

## 1. Hard rules

1. **No predictive telegraphs.** The game cannot know where the operator will strike next. Do
   not draw target circles, landing markers, or "incoming" warnings on the floor. Players dodge
   by watching the dragon itself. These are allowed:
   - the dragon's normal shadow (`CastShadow`);
   - effects that show the arm's *current* state, such as eyes that glow brighter as the jaw
     opens;
   - marks left *after* a hit, such as craters and scorch marks.
2. **The dragon is always where the real arm is.** Place every dragon part from `arm.points` and
   `arm.joints` on every frame. Do not tween, animate or offset the dragon locally: no fake
   recoil, no fake shake, no idle bob. Under `earthquake` the real arm already shakes, so show
   that and add nothing to it. If the visual moves away from the hitbox, hits look unfair.
3. **What you see is what hits.** Hit volumes are the dragon's core segment parts and the drawn
   fire cone and shockwave ring. Never use a hidden radius that is larger than what is drawn.
4. **Effects come from server state.** Debuff visuals read `state.effects` (`name`, `intensity`,
   `remaining`), not the button press that requested them. The server clamps every duration,
   so only `state.effects` has the true values.
5. **A stale arm is a harmless dragon.** If `arm_age` is greater than `STALE_ARM_S`, switch the
   dragon to its dormant look (section 6) and deal no damage until fresh frames arrive.
6. **All colours and fonts come from `roblox/Theme.lua`** (section 3). Do not write `Color3`
   literals anywhere else.
7. **Warm means dragon and danger. Cool means players.** Fire, lava, shockwaves and the dragon
   use reds, oranges and yellows. Power-ups, player abilities and debuffs on the dragon use
   cyan, aqua, violet, magenta, ice and lime. Never give a player effect a warm colour, and
   never give a dragon attack a cool one.
8. No Roblox logo, no real brands. Leave player avatars as they are.

---

## 2. The look

A dark volcanic arena at night, lit almost entirely by lava and fire. Shapes are chunky and
smooth, in the classic Roblox plastic style, not realistic textures. The dragon is a crimson
robot arm wearing scale armour. It must still read as a machine: iron rings at the joints,
bolts, and a bolted pedestal under a dragon skin. The environment is dark and low in saturation
so the three bright things stand out: hazards, the dragon's eyes, and power-ups.

Reference images are in `concepts/refs/`. They are low-resolution previews of the Volcano Slam
concepts.

| File | Shows | Use it for |
|---|---|---|
| `slam.png` | The dragon mid-slam, shockwave, full HUD | The main target look and the HUD layout |
| `windup.png` | The arm raised high, seen from a low camera | The dragon's silhouette against the sky |
| `near-miss.png` | A player-level view behind a runner | Debris, sparks, the player camera |
| `overhead.png` | The whole arena from above, with craters | The operator view, arena layout, impact marks |

Do not copy these parts of the references:
- Any warning circle on the floor (see rule 1).
- The smooth serpent look in `windup.png`. The neck must keep visible joints.
- The pedestal in the centre of the arena in `overhead.png` (see section 5).

---

## 3. Palette and the Theme module

**Brightness order, brightest first:** hazards (fire, shockwave, lava) → power-ups and debuff
effects → the dragon's eyes → the dragon's body → players → environment. If something lower on
this list is brighter than something higher, fix it.

The scene is dark, so these colours look darker in game than they do as swatches. Judge colour
in Play mode under the final lighting.

Create `roblox/Theme.lua`:

```lua
--!strict
-- Every colour and font in the Dragon Arena. Require this; do not write Color3 literals elsewhere.
local Theme = {}

Theme.Color = {
	-- Environment: dark, low saturation, never orange
	Obsidian     = Color3.fromRGB(42, 34, 36),    -- arena floor
	ObsidianDeep = Color3.fromRGB(20, 11, 13),    -- floor cracks, pits, crater centres
	Basalt       = Color3.fromRGB(64, 38, 43),    -- pillars, walls, platforms, boulders
	BasaltEdge   = Color3.fromRGB(96, 66, 68),    -- top bevels, so platform edges read

	-- Heat: the brightest things on screen
	Lava         = Color3.fromRGB(242, 98, 42),
	LavaHot      = Color3.fromRGB(251, 155, 58),  -- shockwave core, body of the fire
	WhiteHot     = Color3.fromRGB(255, 226, 154), -- core of the fire, impact flash
	Ember        = Color3.fromRGB(182, 77, 22),   -- trail tails, cooling craters
	Scorch       = Color3.fromRGB(30, 14, 12),    -- burn marks, smoke

	-- Dragon: mid brightness, warm
	DragonScale  = Color3.fromRGB(168, 40, 28),   -- main armour plates
	DragonShade  = Color3.fromRGB(96, 20, 17),    -- underside, plate edges, dormant body
	DragonSpike  = Color3.fromRGB(43, 10, 9),     -- spikes, horns
	DragonIron   = Color3.fromRGB(58, 52, 54),    -- joint rings, pedestal, bolts
	DragonTooth  = Color3.fromRGB(235, 220, 200),
	DragonEye    = Color3.fromRGB(255, 138, 31),  -- eyes and mouth glow (Neon)

	-- Player side: cool colours only
	Power        = Color3.fromRGB(110, 200, 255), -- generic pickup, "ready" glow, survivors win
	Shake        = Color3.fromRGB(0, 240, 200),   -- earthquake
	Slow         = Color3.fromRGB(124, 108, 255), -- molasses
	Inverted     = Color3.fromRGB(224, 64, 251),  -- mirror
	Frozen       = Color3.fromRGB(191, 239, 255), -- freeze
	Lag          = Color3.fromRGB(154, 166, 178), -- fog
	Jammed       = Color3.fromRGB(166, 226, 46),  -- butterfingers

	-- UI
	UiInk        = Color3.fromRGB(11, 7, 9),      -- panels at Transparency 0.35, text strokes
	UiText       = Color3.fromRGB(255, 255, 255),
	UiDanger     = Color3.fromRGB(255, 72, 56),   -- timer under 10 s, elimination flash
}

-- Builder Sans ships with Roblox.
Theme.Font = {
	Display = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold),
	Label   = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
}

return Theme
```

---

## 4. Materials and lighting

| Surface | Material | Colour token |
|---|---|---|
| Arena floor | `Basalt` | `Obsidian` |
| Floor cracks (few and thin) | `Neon`, Transparency 0.4 | `Ember` |
| Platforms, pillars, cliff walls | `Rock` or `Slate` | `Basalt`, top edge `BasaltEdge` |
| Lava moat, lavafalls | `CrackedLava`, plus `Neon` strips for glow | `Lava` |
| Dragon armour plates | `SmoothPlastic` | `DragonScale`, underside `DragonShade` |
| Dragon spikes, horns | `SmoothPlastic` | `DragonSpike` |
| Joint rings, pedestal, bolts | `Metal` or `DiamondPlate` | `DragonIron` |
| Eyes, mouth glow | `Neon` | `DragonEye` |
| Pickups, debuff overlays | `Neon` or `ForceField` | that effect's colour |
| Frozen dragon | `Ice` | `Frozen` |

Starting lighting values. Tune them in Play mode. Set `Technology` in the Studio Properties
panel, not from a script.

- **Lighting:** Technology `Future`, ClockTime `0`, Brightness `1`, Ambient `(40, 20, 22)`,
  OutdoorAmbient `(60, 30, 30)`, EnvironmentDiffuseScale `0.3`, EnvironmentSpecularScale `0.6`.
- **Atmosphere:** Density `0.38`, Offset `0.1`, Color `(120, 50, 40)`, Decay `(60, 20, 25)`,
  Glare `0.2`, Haze `1.5`.
- **BloomEffect:** Intensity `0.8`, Size `28`, Threshold `1.4`. Neon parts must glow.
- **ColorCorrectionEffect:** Contrast `0.12`, Saturation `0.08`, TintColor `(255, 240, 232)`.
- **Sky:** dark, `CelestialBodiesShown = false`, no stars.
- **Ambient embers:** one `ParticleEmitter` above the arena with small `Ember`/`LavaHot` specks
  drifting up, Rate about 6, LightEmission 1.
- **Lights:** no more than 8 `PointLight`s in the lava (Color `Lava`, Range 20, Brightness 2),
  plus the dragon's mouth light. Neon with Bloom does most of the glow, and lights are
  expensive under `Future`.

---

## 5. The arena

**Shape follows reach.** The arena floor is the area the real tip can reach. The concept art
puts the pedestal in the middle, but the SO-101's shoulder pan does not turn a full circle, so
a round arena gives players a safe spot behind the dragon. To get the real shape, drive the arm
around with the jaw near the table and log `arm.tip` whenever tip `z < ARENA_FLOOR_MM + 10`.
Convert those points with `Mapping.point`. Their outline is the floor. Put the pedestal against
a cliff wall at the back (the dragon's lair) so the floor fans out in front of it. Everything
the dragon cannot reach is lava, cliff or rock. That includes the dead zone close to the base,
where the tip cannot get down to the floor: fill it with the pedestal and rubble. Players must
never find a spot the dragon cannot hit.

**Scale.** `Mapping.lua` stays the only place the scale lives. Pick `STUDS_PER_MM` so that the
reach area fits 12 players with room to run. Players are about 5 studs tall, and the dragon's
head should be 8 to 10 times that. At the shipped `0.46`, a head segment of about 100 mm is
about 46 studs long, which is about right.

**Floor.** Dark `Obsidian`, mostly flat, with low cracked relief. Keep orange off the floor
except at the lava edge and on temporary impact glow, so fire and shockwaves stand out
against it.

**Lava** surrounds the reachable area: `CrackedLava` with Neon strips, slow-rising embers, and
an occasional bubble pop.

**Cover and height.** Add a few basalt rocks and some low floating stone platforms near the
edges. All of them must be inside reach. Rocks block fire (section 7). Give platform heights in
units of the arena's `JumpHeight`.

**Background.** Tall basalt spires with lavafalls, outside the play area, dark against the sky.
They frame the dragon and must never be brighter than it.

**Impact marks.** Each slam leaves a crater decal: an `ObsidianDeep` centre with an `Ember` rim
that fades to `Scorch` over about 3 s. Remove it after about 30 s. Fire leaves `Scorch`
patches. Keep at most about 20 marks; remove the oldest first.

**Real blocks.** In the arena, `BlockSync` blocks become basalt boulders: a `Basalt` cube with a
`BasaltEdge` bevel and a thin Neon vein in the block's real colour, so "the red one" still means
something. The protocol reports a held block as grey. Show it as a boulder in the jaw with an
`Ember` glow.

---

## 6. The dragon

Build it as a new module, `roblox/DragonArm.lua`. Leave `SkyArm.lua` as it is; its own comment
says the 1v1 arm is a separate rig. The input is the same: `arm.points`, from base to tip,
converted with `Mapping.point`.

### Anatomy

| Segment (point *i* → *i+1*) | Dragon part | Thickness, studs (start) | Details |
|---|---|---|---|
| `shoulder_pan` → `shoulder_lift` | Shoulders | 16 | Iron collar, heaviest plates |
| `shoulder_lift` → `elbow_flex` | Lower neck | 14 | Overlapping plates, row of spikes along the top |
| `elbow_flex` → `wrist_flex` | Upper neck | 12 | Plates, spikes |
| `wrist_flex` → `wrist_roll` | Back of the skull | 11 | Two horns swept back |
| `wrist_roll` → `tip` | Head and jaws | 12 wide | Upper jaw, lower jaw, eyes, teeth |

- **Joints.** Every point gets an iron ring (`DragonIron`, `Metal`) with 4 to 6 bolt heads. This
  is where the machine shows through the dragon.
- **Pedestal.** The base point sits on a wide iron drum with bolts, sunk into rock, with a ring of
  Neon `Ember` cracks around its foot.
- **Silhouette.** From any angle it reads as a curved neck and a head: spikes on top, the darker
  `DragonShade` underside below. Against the sky, the row of spikes and the horns must make it
  unmistakable.
- **Head.** A wedge, longer than it is wide. The upper jaw is fixed to the head. The lower jaw is
  hinged at the back of the head and opens with `arm.joints.gripper`. Two Neon eyes sit on the
  upper jaw, with a row of `DragonTooth` teeth. The inside of the mouth is `DragonEye` Neon,
  mostly transparent when shut, and it glows more as the jaw opens.

### Construction rules

- **Build once, then move.** Link lengths never change, because the points come from forward
  kinematics on the real URDF. Build each segment once from the first frame's span, then move it
  only with `Model:PivotTo` on each Heartbeat. Do not resize segments each frame, or the
  decorations stretch.
- **Do not orient with a plain `CFrame.lookAt(a, b)`.** Its default up vector is world up. In a
  slam the head points straight down, so it flips and spins. Use the normal of the arm's plane as
  the up vector instead: the plane through the shoulder, elbow and wrist points. When the arm is
  straight that plane is undefined, so keep the previous frame's normal. This keeps the spikes
  on top.
- **Head roll comes from `arm.joints.wrist_roll`**, because the points alone do not define it.
  Check the sign once: roll the real wrist and confirm the head turns the same way.
- **Lower-jaw angle.** Map the gripper reading onto 0° to 40°, using the jaw's observed range
  learned at run time, the same way `bridge/board.py` `ReleaseTrigger.feed` does. The reading is percent
  open, roughly 8 when shut and 50 or more when open, but it differs from arm to arm.
- **Decorations** are `Anchored`, and `CanCollide`, `CanQuery` and `CanTouch` are all false. The
  core segment parts are the hitbox (`CanQuery = true`). Check them with `GetPartsInPart`, as
  `SkyArm:partsTouching` does.
- **Part budget:** about 80 parts for the whole dragon. Boxes, wedges and cylinders are fine.
  Blender meshes are a stretch goal.

### Dragon states

| State | When | Look |
|---|---|---|
| Live | Default | As above, eyes steady |
| Jaw opening | Gripper reading rising | Eye and mouth glow grow with the opening; small ember sparks at the lips |
| Dormant | `arm_age > STALE_ARM_S` | Body turns `DragonShade`, eyes off, thin smoke from the joints, HUD chip "DRAGON OFFLINE". No damage |
| Debuffed | Any entry in `state.effects` | Section 8, layered on top of Live |

---

## 7. Attacks: how the game detects them, and how they look

The game detects attacks from the arm's motion as they happen, on the server, from successive
state frames. Work out tip velocity from each frame's `ts`, not from Heartbeat's delta time,
because `Bridge` skips frames. Smooth the velocity over about 3 frames.

**The floor is above the real table.** The arena floor matches a height *above* the real table
(`ARENA_FLOOR_MM`), so the dragon's head hits the in-game floor while the real jaw is still in
the air. The operator must never have to bang the arm into the table. Place the floor surface at
`Mapping.point({x = 0, y = 0, z = ARENA_FLOOR_MM}).Y`.

Every value below is a starting guess, not a measurement. Tune them in teleop with the real arm,
and log tip speed first. The follower limits how far it can move each tick
(`max_relative_target = 10` in `robot/arm.py`), so its top speed is capped. Set speed thresholds
from logged real slams, not by feel.

| Constant | Start | Meaning |
|---|---|---|
| `ARENA_FLOOR_MM` | 25 | Real height above the paper that counts as the arena floor |
| `SLAM_HEIGHT_MM` | 12 | A tip this close to the floor counts as contact |
| `SLAM_SPEED_MMS` | 200 | Minimum downward tip speed for a slam |
| `SLAM_REARM_MM` | 60 | The tip must rise this far above the floor before it can slam again |
| `SLAM_RADIUS` | 35 studs | How far the shockwave ring travels |
| `SWEEP_HEIGHT_MM` | 40 | A tip this close to the floor counts as low |
| `SWEEP_SPEED_MMS` | 150 | Minimum sideways tip speed for a sweep |
| `FIRE_OPEN_FRAC` | 0.7 | Share of the jaw's observed range that counts as open |
| `FIRE_MIN_PCT` | 30 | Lowest gripper reading that can breathe fire, safely above butterfingers' 18 |
| `FIRE_RANGE` | 60 studs | Length of the fire cone |
| `FIRE_HALF_ANGLE` | 18° | Half-angle of the fire cone |
| `STALE_ARM_S` | 0.5 | `arm_age` above this makes the dragon dormant |

### Slam

**Detect:** the tip comes within `SLAM_HEIGHT_MM` of the arena floor while moving down faster
than `SLAM_SPEED_MMS`. Count one slam per descent: re-arm only after the tip rises above
`SLAM_REARM_MM`.

**Look**, at the tip's position on the floor, in this order:
1. Impact flash: a `WhiteHot` Neon disc for 0.08 s.
2. Shockwave ring: a flat Neon ring, `LavaHot` at the core fading to `Ember` at the edge. It
   grows from the head's width to `SLAM_RADIUS` over about 0.45 s while fading out. Keep it low
   and thin so it clearly looks like something a player can jump over.
3. Debris: 6 to 10 `Basalt` chunks thrown up and out, removed after 2 s (`Debris` service).
4. A burst of dust and embers with `ParticleEmitter:Emit()`: dark smoke and `LavaHot` sparks.
5. Camera shake for each player, stronger when closer, none beyond about 2 × `SLAM_RADIUS`, at
   most 0.4 s.
6. A crater decal (section 5).

### Sweep

**Detect:** the tip is within `SWEEP_HEIGHT_MM` of the floor and moving sideways faster than
`SWEEP_SPEED_MMS`.

**Look:** a `Trail` on the head and the upper neck, `Ember` fading to transparent, Lifetime
0.3 s, enabled only while sweeping. A spark emitter at the tip scraping the ground (`LavaHot`,
on only while sweeping), and a low dust wake. Knockback goes in the direction of the tip's
sideways velocity.

### Fire breath

**Detect:** the jaw is open by at least `FIRE_OPEN_FRAC` of its observed range **and** the
gripper reading is at least `FIRE_MIN_PCT`. The second check matters because `butterfingers`
holds the jaw at least 18% open, and that must never turn into free fire.

**Look:** from a mouth `Attachment`, pointing along the head's forward axis (`wrist_roll` →
`tip`):
- A `ParticleEmitter` whose colour runs `WhiteHot` → `LavaHot` → `Lava` → `Ember` → `Scorch`
  smoke. Speed 60 to 90, SpreadAngle 15 to 20, Lifetime 0.6 to 0.9, LightEmission 1, size
  growing over its life.
- Rate and speed grow with how far the jaw is open. This shows the current state; it is not a
  wind-up.
- A flickering `Lava` `PointLight` at the mouth, Range about 30.
- `Scorch` patches where the cone meets the floor.
- The fire stops on the same frame the jaw drops below the threshold.

**Hit volume:** the drawn cone (`FIRE_RANGE`, `FIRE_HALF_ANGLE`), plus a raycast from the mouth
so rocks and platforms give cover. Match the particle spread to the cone.

Attacks can combine; fire while sweeping is fine. Each attack has its own detector.

---

## 8. Power-ups and debuffs

Players' power-ups send `event` frames (see `PROTOCOL.md`). Build the list from `hello.effects`;
do not hard-code it. The designer's three debuffs are shake = `earthquake`, slow = `molasses`
and inverted controls = `mirror`. The other three also exist.

| Effect | Name players see | Colour token | Dragon look while active | Max duration (server) |
|---|---|---|---|---|
| `earthquake` | SHAKE | `Shake` | Aqua electric arcs jump between the joint rings; sparks fly off the plates. The visible wobble is the real arm, so add none | 5 s |
| `molasses` | SLOWED | `Slow` | An indigo `ForceField` sleeve around the neck, with slow drifting particles | 10 s |
| `mirror` | INVERTED | `Inverted` | Magenta glitch: a Neon magenta overlay flickers on the segments a few times a second | 15 s |
| `freeze` | FROZEN | `Frozen` | Plates turn to `Ice` in `Frozen`, with ice shards on the joints. A shatter burst when it ends | 3 s |
| `fog` | LAGGING | `Lag` | Thick smoke wraps the head and the eyes dim; the dragon is half blind (the real arm lags) | 10 s |
| `butterfingers` | JAW JAMMED | `Jammed` | A lime-glowing boulder is stuck in the jaw, so the lower jaw cannot fully close | 8 s |

Rules:
- **Players caused these, so never punish the players' screens.** No player camera shake, no
  fog over the players' view, no flipped player screen. The Roblox-side effects in the
  `plan.md` table (camera shake, fog, screen flip) were written for the obby. In the arena they
  go on the dragon and on the operator's screen.
- Overlays sit on the live dragon and follow it exactly (rule 2). Several effects can stack.
- Read `remaining`, and fade each overlay out over its last 0.5 s so players see it ending.

**Pickups:** a floating Neon crystal, 3 to 4 studs, in its effect's colour (or `Power` for
generic abilities). It bobs up and down 1 stud, turns slowly, and has a `PointLight` (Range 10)
in its colour, with a soft glow on the floor directly under it. Use the same icon on the pickup
and in the HUD slot. Spawn pickups only inside the dragon's reach.

**When a player lands a debuff:** show a toast at the top centre, such as "DRAGON SLOWED!", in
the effect's colour for 1.5 s, with the player's name in small text under it. Under the timer,
show one chip per active effect: icon and seconds remaining, with a border in the effect's
colour.

---

## 9. HUD and UI

Layout, matching `slam.png`:

- **Top left, survivors pill:** a `UiInk` panel at Transparency 0.35, corner radius 8.
  "SURVIVORS" in `Label` 16 px, and the count ("9/12") in `Display` 20 px, both `UiText`. The
  count flashes `UiDanger` briefly when a player is eliminated.
- **Top centre, timer:** M:SS in `Display` 48 px, `UiText`, with a 3 px `UiInk` `UIStroke`.
  Under 10 s it turns `UiDanger` and pulses gently. Active-effect chips sit under it.
- **Bottom right, ability bar:** 3 or 4 square slots, 64 px (big enough for touch), `UiInk`
  tiles with a 2 px `UiText` border and white icons. A ready slot glows `Power` (`UIStroke`,
  thickness 3). Cooldown is a bottom-up fill in `UiInk` at Transparency 0.5. A slot holding a
  picked-up debuff has a border in that effect's colour.
- Nothing else stays on screen. Banners (round start and end, debuff toasts) appear at the top
  centre and leave.

**Type:** Builder Sans (`Theme.Font`). `Display` (ExtraBold) for numbers and banners, `Label`
(Bold) for labels. Labels and banners are all caps. Every text element gets a 2 to 3 px `UiInk`
`UIStroke`, because the scene behind it is busy.

**Small screens:** size with Scale or `UIScale`, and test at phone size. Slots never go below
56 px.

### Round flow

- **Countdown:** "3 · 2 · 1 · SURVIVE!" in the centre, `Display` 96 px, with the last word in
  `Lava`.
- **Survivors win:** "SURVIVORS WIN" in `Power`, with the survivors' names below.
- **Dragon wins:** "THE DRAGON WINS" in `Lava`, and the dragon's eyes flare. Do not make the
  dragon move for this (rule 2).
- **Eliminated:** the character breaks into blocky pieces (the default
  `Humanoid.BreakJointsOnDeath`) with a small ember burst. The player then spectates a survivor,
  with "SPECTATING <name>" in small text at the bottom centre.

---

## 10. Cameras

- **Players:** the default third-person camera. Do not replace it.
- **Operator screen:** a fixed, high overhead camera over the whole arena (`overhead.png`),
  tilted slightly toward the pedestal so the operator sees what is in front of the dragon. On
  this view only, give every live player a white `Highlight` (OutlineColor `UiText`,
  FillTransparency 1), because dark avatars disappear against obsidian from above. Show debuffs
  that affect the operator (for example "CONTROLS INVERTED") in large text here.

---

## 11. Sound

A volcano ambience underneath everything (low rumble, bubbling lava). A dragon roar when fire
starts, a looping flame roar while it lasts, a deep boom for slams, a grinding scrape for
sweeps. A bright chime for pickups, a zap when a debuff lands, a pop when a player is
eliminated, ticks for the last 10 s. Dragon sounds are low and heavy; player sounds are high
and bright, the same warm and cool split as the colours. Use Roblox's audio library, and no
copyrighted music.

---

## 12. Performance budget

- About 80 dragon parts, moved with `PivotTo` each Heartbeat.
- At most 8 environment `PointLight`s.
- Use `ParticleEmitter:Emit()` for one-off hits and toggle `Enabled` for continuous effects.
  Keep total particles on screen to about 400 or fewer.
- At most 20 impact decals at once.
- Trails only on the head and the upper neck.

---

## 13. Checklist before you finish a visual change

- [ ] No floor marker predicts an attack.
- [ ] Dragon parts sit exactly on `arm.points`, and nothing animates the dragon locally.
- [ ] Hit volumes match what is drawn.
- [ ] No `Color3` literal outside `Theme.lua`.
- [ ] Warm means dragon and danger, cool means players, everywhere.
- [ ] Fire cannot start from the 18% butterfingers floor.
- [ ] The dragon goes dormant and harmless when `arm_age` is stale.
- [ ] Text is readable in a phone-sized window.
- [ ] Checked in Play mode under the final lighting.

---

## 14. Values still to measure on the real arm

| Value | How to get it |
|---|---|
| `ARENA_FLOOR_MM` | The lowest height the real jaw can sit above the table without risk |
| Arena outline | Log tip positions near the floor (section 5) |
| `SLAM_SPEED_MMS`, `SWEEP_SPEED_MMS` | Log tip speed during real slams and sweeps; start the threshold at about 70% of a typical one |
| `FIRE_OPEN_FRAC`, `FIRE_MIN_PCT` | Have the operator open the jaw to "breathe". Check that it never fires while the jaw holds a block |
| `wrist_roll` sign | Roll the real wrist and compare with the head |
| Lower-jaw max angle | By eye; 35° to 45° reads as a roar |
