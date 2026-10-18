# roblox/arena/ — Dragon Arena

One operator drives the real SO-101 with the leader arm. In here that arm is a giant dragon in a
volcanic arena, attacking up to twelve players by slamming its head into the ground, sweeping
across the floor, and opening its jaw to breathe fire. Players dodge, and grab power-ups that send
real effects back to the real arm. Players still alive when the timer ends win; if nobody is left,
the dragon wins.

The look is set by [`../../concepts/dragon-arena-style-guide.md`](../../concepts/dragon-arena-style-guide.md).
The wire format is [`../../PROTOCOL.md`](../../PROTOCOL.md). This file covers how to run it.

This mode shares `Bridge.lua` and `Mapping.lua` with the obby build in `../`. It does not touch
`Main.server.lua`, `SkyArm.lua` or `BlockSync.lua` — paste either that mode or this one, not both.

## Setup

There are three ways in. All three produce the same tree; the difference is what happens when two
people change things at once.

**Open the place file.** `DragonArena.rbxlx` in this folder is a complete Studio place - open it,
press Play. Fastest way to see the mode, and the right thing to hand someone who just wants to
look at it. Read the warning under *Combining this with other games* before committing a saved
copy of it.

**Sync with [Rojo](https://rojo.space)** (`roblox/default.project.json`). Install Rojo and the
Studio plugin, then from `roblox/`: `rojo serve`, and hit Connect in the plugin. The `.lua` files
on disk become the tree in Studio and stay in sync as you edit. This is the one to use if you are
going to change anything, and the only one that merges sanely with other people's work.

**Paste by hand.** The tree is below if you would rather build it yourself.

Either way, two settings:

1. **Game Settings → Security → Allow HTTP Requests: on.** Nothing works without this.
2. **Lighting → Technology: `Future`.** Set it in the Properties panel, not from a script. The
   arena's Neon-and-Bloom look depends on it, and scripting it mid-session does not give the same
   result as shipping it.

The tree:

```
ReplicatedStorage
  Arena                    (Folder)
    Theme                  (ModuleScript)
    ArenaConfig            (ModuleScript)
    Remotes                (ModuleScript)

ServerScriptService
  Bridge                   (ModuleScript)   <- from ../Bridge.lua, unchanged
  Mapping                  (ModuleScript)   <- from ../Mapping.lua, unchanged
  ArenaMain                (Script)         <- ArenaMain.server.lua
  Arena                    (Folder)
    Arena                  (ModuleScript)
    DragonArm              (ModuleScript)
    AttackDetect           (ModuleScript)
    AttackFx               (ModuleScript)
    DragonEffects          (ModuleScript)
    Pickups                (ModuleScript)
    Rounds                 (ModuleScript)
    Sound                  (ModuleScript)

StarterPlayer
  StarterPlayerScripts
    ArenaHud               (LocalScript)    <- ArenaHud.client.lua
```

4. Start the robot process: `python -m bridge.main --source mock`
5. Press **Play**. The output window should show `[Bridge] hello: ...` then
   `[Arena] source=mock, floor from sheet 279 x 216 mm, arm base (...)`.

If Studio is on a different machine from the robot, change `URL` in `ArenaMain` from `localhost`
to the robot laptop's LAN IP.

## The aerial view

**Press `V`.** Any client toggles between the normal player camera and the aerial operator view —
fixed high camera over the whole arena, white outlines on every player, no ability bar, and
operator-facing debuff text ("CONTROLS INVERTED") across the top. There is a reminder in the
top-right corner of the screen.

The server can also assign it on join: set `OPERATOR_NAME` in `ArenaMain` to a Roblox username.
That player is excluded from the round and gets no character, which is what you want for a real
operator who is holding the leader arm rather than playing. Left empty, nobody is assigned — the
right default for a public server, and the `V` key still works for everyone.

Use the key, not the name, when you are setting up screens in a hurry: in Play Solo your player is
named after your Roblox account rather than `Player1`, so a name match is exactly the thing that
fails right when you are trying to get a second display up.

If `V` reports `NO ARENA YET — START THE ROBOT PROCESS`, the floor does not exist because no
`hello` frame has arrived. That is the robot process not running, not the keybind.

## Combining this with other games

Several people are building separate modes in this repo, and they will eventually go into one
place. **Do not make a committed `.rbxl` the thing everyone edits.** A binary `.rbxl` is opaque to
git: it cannot be merged, cannot be diffed, and two people saving the same place means one of them
loses their work with no warning and no way to recover it from the history. `.rbxlx` is XML, so git
will *attempt* a merge, which is worse - referents and child ordering produce a file that merges
cleanly and then will not open.

The `.lua` files are the source of truth here. `DragonArena.rbxlx` is a build artifact, generated
from them, and it is committed because it is genuinely useful for opening and for merging into a
combined place - not because it is the master copy. If you edit in Studio against the place file,
your changes live only in the place file and the modules here go stale.

For the combined place, the path that works is Rojo: each mode keeps its own folder of `.lua`
files and its own project file, one person owns the combined place, and each mode syncs into its
own branch of the tree. The layout here is already shaped for that - `arena/` mirrors the Studio
hierarchy exactly, and nothing in this mode writes outside `ReplicatedStorage.Arena`,
`ServerScriptService.Arena`, `ServerScriptService.ArenaMain` and one LocalScript.

The one real collision to watch for: `Bridge` and `Mapping` are shared with the obby and sit at the
top of `ServerScriptService`. If two modes both ship a copy, the second one to sync wins. They
should end up owned by one place in the combined tree, with every mode requiring that copy.

## Where the arena comes from

**The floor is the printed sheet.** The style guide (section 5) asks for the floor to be the
outline the real tip can reach, found by driving the arm around with the jaw near the table and
logging `arm.tip`. That has not been done. Until it is, the floor is the sheet rectangle, sized
from `hello.space.sheet` — the honest stand-in, because it is the actual work surface in front of
the arm rather than a guess, and every block the game knows about sits on it.

The pedestal goes at `hello.space.arm_base_mm`, which is off the **top** edge of the sheet: the arm
really does stand behind the paper. So the guide's layout falls out of the real geometry for free —
the dragon is at the back against the cliff and the floor fans out in front of it, with no round
arena and so no safe spot behind the dragon where the shoulder pan cannot turn.

When the reach outline is finally logged, it replaces `Arena.floorFromSheet` and nothing else
changes. `Arena.lua` is the only file that knows the floor's shape.

## What is a guess and what is measured

Almost every threshold in `ArenaConfig.lua` is a **starting value from the style guide, not a
measurement**. Do not treat one as settled because the demo worked once. Section 14 of the style
guide lists how to get each properly; the short version:

| Value | How to get it |
|---|---|
| `ARENA_FLOOR_MM` | The lowest height the real jaw can sit above the table without risk |
| `SLAM_SPEED_MMS`, `SWEEP_SPEED_MMS` | Log tip speed during real slams and sweeps; start at ~70% of a typical one |
| `FIRE_OPEN_FRAC`, `FIRE_MIN_PCT` | Have the operator open the jaw to "breathe". Check it never fires while the jaw holds a block |
| `wrist_roll` sign | Roll the real wrist and confirm the head turns the same way. Flip it in `DragonArm.update`, not in `Mapping` |
| `JAW_MAX_DEG` | By eye; 35°–45° reads as a roar |
| Arena outline | Log tip positions near the floor (above) |

The follower caps how far it can move per tick (`max_relative_target = 10` in `robot/arm.py`), so
its top speed is bounded — **a speed threshold set above that can never fire at all.** Log first.

## Four things that are easy to get wrong

**The dragon is never animated locally.** Every part is placed from `arm.points` each frame, with
`Model:PivotTo`. No tween, no eased rest pose, no idle bob, no fake recoil — and under `earthquake`
no added shake, because the real arm is already shaking and that shake arrives in the points. If
the visual drifts off the hitbox, hits look unfair. `DragonEffects` only *reads* the dragon's pose;
it never writes to it.

**Not `CFrame.lookAt(a, b)`.** Its default up vector is world up, so in a slam — head pointing
straight down — the look direction goes parallel to it and the CFrame flips and spins, putting the
spikes underneath at the exact moment players are watching the head. `DragonArm` uses the normal of
the arm's own plane (through `shoulder_lift`, `elbow_flex`, `wrist_flex`) instead, which is
perpendicular to every segment by construction. When the arm straightens, that plane is undefined,
so the previous frame's normal is kept rather than snapping to something arbitrary.

**The jaw's range is learned, not assumed.** What reading means "open" depends on the gripper and
its calibration, so a hardcoded percentage that is wrong for this arm pins the jaw shut and the
dragon never breathes fire. `DragonArm:jawFraction` and `AttackDetect:jawFraction` both mirror
`bridge/world.py` `_grip_state`: learn the span as it runs, fall back to a constant until it is
wide enough to mean anything.

**Fire needs two tests, and the second is the point.** `butterfingers` holds the jaw at least 18%
open for its whole duration (`BUTTERFINGERS_OPEN_PCT` in `bridge/effects.py`). On the learned range
alone, a jaw jammed that far open can read as a roar — so a player spending a power-up to jam the
dragon's jaw would instead hand it eight seconds of free fire. `FIRE_MIN_PCT` is an absolute floor
set safely above 18, and it has to be absolute, because the learned range is exactly what the
debuff distorts.

## Hit volumes are the drawn thing

Nothing in here uses a hidden radius larger than what is on screen:

- **Slam** — the shockwave is built as sixteen arc chunks around the circumference, and the hit test
  is the band at the ring's current radius. A flat cylinder was the obvious build and is wrong: a
  filled disc draws a danger area that is mostly safe, and players learn to stop believing it.
- **Sweep** — overlap against the dragon's own core segment parts, via `GetPartsInPart`. Anchored,
  CFrame-driven parts do not fire `Touched` reliably, so the server checks each Heartbeat, the same
  way `SkyArm:partsTouching` does.
- **Fire** — the drawn cone, `FIRE_RANGE` long and `FIRE_HALF_ANGLE` wide, with a raycast per
  candidate so rocks and platforms give real cover. Widen the cone and you must widen the particles
  with it.

## Effects come from server state

Every debuff overlay and every HUD chip reads `state.effects` — the list Python sends, with the
name, intensity and `remaining` it actually applied — never the request that asked for it. Python
clamps every duration to its own caps, so a request for 30 s of freeze becomes 3 s, and anything
trusting the request would sit there showing 27 seconds of a debuff that already ended.

The players cause these, so they never punish the players' screens: no player camera shake, no fog
over the player's view, no flipped player screen. `plan.md`'s table describes those for the obby,
where the *player* is the one being messed with. Here the player is the one doing the messing, so
every effect lands on the dragon and on the operator's screen. The one thing that does shake a
player's camera is a slam, which is the dragon's doing.

## Known gaps

- **Sound asset ids are empty.** `Sound.lua` has the full list of cues with ids set to `0`, which
  no-ops. Picking them means browsing the Roblox audio library and listening; an invented
  `rbxassetid` either fails silently or plays something nobody chose. Fill them in and check the
  licence — no copyrighted music.
- **Effect icons are empty.** `Theme.Effect[*].icon` is `rbxassetid://0`. The HUD falls back to the
  effect's text label, which is readable but not the icon the style guide asks for on the pickup
  and the matching slot.
- **The arena outline is the sheet, not measured reach** (above).
- **`GRIP_CLOSED_PCT` / `GRIP_EMPTY_PCT` in `bridge/world.py` are inferred, not measured**
  (`HANDOFF.md`). The learned-span fallback here means the dragon degrades gracefully rather than
  breaking, but the fallback constant `GRIP_OPEN_PCT` inherits the same uncertainty.
- **Not play-tested with the real arm**, so every threshold is still a guess and the lighting has
  not been judged in Play mode under final lighting, which the style guide asks for before calling
  a visual change done.
- **No damage model.** A hit eliminates outright. That is a design decision as much as a visual one;
  `ArenaConfig.HIT_GRACE_S` and the knockback values are there, but there is no health.
