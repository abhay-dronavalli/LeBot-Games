# roblox/

The Roblox side of the bridge. Five files: paste them into Studio as-is, press Play, and the
Sky Arm mirrors the real arm while real blocks become platforms.

The wire format is [`../PROTOCOL.md`](../PROTOCOL.md).

## Setup

1. **Game Settings → Security → Allow HTTP Requests: on.** Nothing works without this.
2. In `ServerScriptService`, create four **ModuleScripts** named `Bridge`, `Mapping`,
   `SkyArm`, `BlockSync`, and one **Script** named `Main`. Paste each file in. (`Main.server.lua`
   is the Script; the rest are the modules.)
3. Start the robot process: `python -m bridge.main --source mock`
4. Press **Play**. The output window should show
   `[Bridge] hello: source=mock protocol v1, 6 effects`.

If Studio is on a different machine from the robot, change `URL` in `Main` from `localhost` to
the robot laptop's LAN IP.

To prove the return direction, run this in the command bar while playing:

```lua
require(game.ServerScriptService.Bridge).sendEvent("earthquake", 0.7, 4)
```

The real arm shakes for four seconds. In mock mode, the mock arm shakes — the effect runs on
the same code path either way, so it is testable before the hardware exists.

## Files

| File | Role |
|---|---|
| `Bridge.lua` | The link. Connects, decodes, reconnects, and sends events. |
| `Mapping.lua` | Sheet mm → studs. **The only place the scale lives.** |
| `SkyArm.lua` | The giant arm that mirrors the follower. |
| `BlockSync.lua` | One platform per real block, rideable. |
| `Main.server.lua` | Wires the above together. The smallest thing that proves the link. |

## Three things that are easy to get wrong

**The Sky Arm needs no rig calibration.** Python sends the arm as a stick figure of *world
points* in sheet mm, not raw joint angles, so segment *i* is just the part spanning
`points[i]` and `points[i+1]`. There are no link lengths here, no Motor6D assembly, and no
per-joint sign or offset to discover by wiggling one real joint at a time — the real
kinematics already ran in Python against the arm's own URDF and fitted calibration.

**Platforms must not be anchored.** An anchored part moved by setting its `CFrame` does *not*
carry a character standing on it: the player slides off, is left behind, or gets flung. Since
the crane lift (a player riding a platform the real arm carries) is the demo's money shot,
`BlockSync` uses **unanchored** parts driven by `AlignPosition` + `AlignOrientation` with the
server as network owner, and caps speed at 60 studs/s so a jumpy camera frame cannot launch
the rider. Held blocks also stay `CanCollide = true`: collision is the thing the player stands
on, so switching it off while held (as an earlier version did) removed the ride entirely. The
speed cap, not loss of collision, is what keeps the rider safe. If riding still proves
unreliable, `BlockSync:attachRider(id, character)` welds the player on for the duration of a
lift.

**Read the newest frame, not the next one.** Python sends 30 frames a second whether or not
anything reads them, so a slow handler falls behind as frames queue in the socket.
`Bridge.lua` therefore only *stores* the latest state in `MessageReceived` and applies it on
`Heartbeat`. Dropping a frame is correct — the next one is always more current. Do not add a
queue.

**Constraints need a force limit raised to match the part.** `AlignPosition.MaxForce` defaults
to 10000. A platform is ~22 x 6.5 x 22 studs at density 0.7, about 2200 mass, so its weight at
the default gravity is ~4.3e5 — 43x the limit. Under-powered, the constraint cannot hold the
part up at all: platforms sag to the floor, and a *held* block (`CanCollide = false`, so nothing
catches it) sinks through the world until the engine destroys it at `FallenPartsDestroyHeight`,
after which the block is gone for the session. `BlockSync` sets `MaxForce`/`MaxTorque` to 1e8
and keeps the rider speed cap in `MaxVelocity`, where it belongs. `update` also rebuilds any
platform whose part has left the tree, so a lost part recovers instead of vanishing silently.

**A held block arrives grey, so colour must be set every frame.** While a block is in the jaw
its position comes from forward kinematics, which knows where the jaw is but nothing about what
it holds, so Python reports `color = "grey"` for the duration and the real colour again on
release. A part coloured only in `create` would keep whatever it was when it first appeared, so
`update` refreshes `p.Color` on every frame. The Python side keeps the true colour internally
for block association; grey is a display state, not a loss of information.

## Tuning the scale

Everything scale-related is in `Mapping.lua`, and nothing on the Python side depends on it, so
change it live:

```lua
Mapping.STUDS_PER_MM = 0.46      -- the sheet becomes about 129 x 99 studs
```

One scale now applies to all three axes, so a 48 mm block is a true 22-stud cube. An earlier
version scaled height separately (`LEVEL_STUDS = 6.5`) so that one block was exactly one
jumpable step, but a carried block then looked like a slab rather than a cube — and the carried
block is the one the player rides, so it is the one that has to look right.

The cost is that 22 studs is far above the ~7 studs a default character clears, so nothing
would be climbable. `Main` therefore scales the *player* to the block instead: on spawn it sets
`UseJumpPower = false` and `JumpHeight = Mapping.jumpHeight(cubeMm)` (one cube plus 5 studs of
margin). Change the cube scale and the jump follows automatically — don't hardcode a jump
number anywhere else.

`Mapping.ORIGIN` moves the whole build zone, which is how the level ↔ table mapping in
`plan.md` works: when the player reaches level N, move the origin to level N's build zone.

## Not built here

Game modes, the 1v1 arena, pattern match, and the in-game visual effects. They read from
`Bridge.onState` and should not need to touch `Bridge` itself. Two hooks are already in place
for the arena: `SkyArm:tip()` for where the jaw is, and `SkyArm:partsTouching()`, which checks
overlap on the server each `Heartbeat` because anchored CFrame-driven parts do not fire
`Touched` reliably.
