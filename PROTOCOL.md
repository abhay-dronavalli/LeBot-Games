# Protocol

The wire format between the robot laptop and Roblox. Version **1**.

One Python process owns the arm and the camera and serves this over a WebSocket. Roblox
Studio connects *out* to it:

```lua
local ws = HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
    Url = "ws://localhost:8765",      -- or the robot laptop's LAN IP
})
```

**There is no middle server, and there cannot be one.** Only one process can hold the
follower's COM port, so the process that drives the arm has to be the same one that serves
the socket. A separate "robot reader" service is not possible.

Frames are JSON, one object per message, each tagged with `t`.

## Coordinates

Everything the server sends is in the **sheet frame, millimetres**:

- origin at the printed sheet's top-left corner
- `+x` right, `+y` down the page (away from the arm, which sits off the top edge)
- `+z` up off the paper, so `z = 0` is the paper surface

The sheet is US Letter, 215.9 × 279.4 mm, with a 3×3 grid of 57.15 mm cells. The arm's
shoulder-pan axis is at about `(115, -44)`, i.e. off the top edge, centred.

The **client** converts mm to its own units, so the scale is retuned in Roblox without
restarting Python. For Roblox, which is Y-up:

```
roblox_X = sheet_x * studs_per_mm
roblox_Z = sheet_y * studs_per_mm
roblox_Y = level * level_studs          -- resting: height comes from stack level
roblox_Y = sheet_z * studs_per_mm       -- held: the real carry height is the point
```

Horizontal scale and height scale are **independent on purpose**. Scaling height by the same
factor would make a 48 mm cube 22 studs tall, far above the ~7-stud default jump, so no stack
would ever be climbable. `roblox/Mapping.lua` ships `studs_per_mm = 0.46` and
`level_studs = 6.5`: the sheet becomes 99 × 129 studs, one block is a jumpable step, and a
three-block wall (19.5 studs) is not. That is the scale rule.

Joint angles are **degrees as the follower reports them** — not URDF angles, not normalised.
Python applies the fitted zero offsets before sending.

## Server → client

### `hello` — once, on connect

Static geometry, sent before any state frame.

```json
{"t":"hello","v":1,"source":"mock","state_hz":30.0,
 "joints":["shoulder_pan","shoulder_lift","elbow_flex","wrist_flex","wrist_roll","gripper"],
 "effects":["butterfingers","earthquake","fog","freeze","mirror","molasses"],
 "space":{
   "frame":"sheet mm: origin at the sheet's top-left corner, +x right, +y down the page ...",
   "sheet":{"w_mm":215.9,"h_mm":279.4},
   "grid":{"origin_mm":[22.225,48.26],"cell_mm":57.15,"rows":["A","B","C"],"cols":[1,2,3],
           "naming":"letter is the row (A nearest the arm), number is the column"},
   "cube_mm":48.0,
   "arm_base_mm":[115.2,-44.5],
   "suggest":{"studs_per_mm":0.46,"level_studs":6.5}}}
```

`source` is `mock`, `teleop` or `auto`, so the client can show what is driving the arm.
`effects` is the authoritative list of effect names the server accepts — build the UI from it
rather than hard-coding names.

### `state` — 30 Hz

```json
{"t":"state","seq":1042,"ts":1760700000.12,
 "arm":{
   "joints":{"shoulder_pan":12.1,"shoulder_lift":-40.3,"elbow_flex":55.0,
             "wrist_flex":20.2,"wrist_roll":-3.0,"gripper":34.0},
   "points":[{"name":"shoulder_pan","x":115.2,"y":-44.5,"z":69.1},
             {"name":"shoulder_lift","x":87.0,"y":-23.0,"z":123.3},
             {"name":"elbow_flex","x":108.3,"y":-76.7,"z":223.9},
             {"name":"wrist_flex","x":69.0,"y":22.5,"z":306.6},
             {"name":"wrist_roll","x":75.8,"y":54.5,"z":251.9},
             {"name":"tip","x":60.9,"y":92.4,"z":152.5}],
   "tip":{"x":60.9,"y":92.4,"z":152.5}},
 "arm_age":0.03,
 "blocks":[{"id":1,"color":"red","x":50.8,"y":76.8,"z":0.0,"yaw":0.0,
            "level":0,"held":false,"visible":true,"age":0.0}],
 "blocks_age":0.09,
 "effects":[{"name":"earthquake","intensity":0.7,"remaining":2.31}],
 "notes":{"script":"carry to C3"}}
```

**`arm.points` is the important field.** It is the arm as a stick figure of *world points*,
base to tip, already in the sheet frame. So the Roblox rig needs no link lengths, no Motor6D
assembly, and no per-joint sign or offset calibration: segment *i* is simply the part spanning
`points[i]` and `points[i+1]`. The real kinematics already ran in Python against the arm's own
URDF and its fitted calibration.

`arm.tip` is the jaw tips, the same as the last entry of `points`.

Blocks:

| Field | Meaning |
|---|---|
| `id` | Stable across frames. One platform per id. Not derived from colour. |
| `color` | A name, for looks. Identity is `id`; a wrong colour is cosmetic. |
| `x`, `y` | Sheet mm. `z` is height above the paper. |
| `yaw` | Degrees, counterclockwise from above, wrapping every 90°. |
| `level` | Stack level. 0 is on the paper. Height in game comes from this, not from `z`. |
| `held` | In the gripper. Its position is the FK tip, and `z` is the real carry height. |
| `visible` | The camera can see it right now. `false` means the pose is remembered, not fresh. |
| `age` | Seconds since it was last confirmed. |

`arm_age` and `blocks_age` are seconds since each part was last updated. Blocks update slower
than the arm (perception is ~10 Hz, the arm is 30 Hz), and on a bus dropout or a lost sheet
these climb — grey the Sky Arm out rather than trusting a stale pose.

`notes` is free-form diagnostics (`script` in mock mode, `sheet` fit error, `bus_error`).
Do not depend on its keys.

### `pong`

```json
{"t":"pong","id":7,"ts":12345.6}
```

### `error`

```json
{"t":"error","message":"unknown effect 'nonsense'","frame":null}
```

Sent on a bad frame. The server never drops the connection over one.

## Client → server

### `event` — make something happen to the real arm

```json
{"t":"event","name":"earthquake","intensity":0.7,"duration":4}
```

| Name | In Roblox | To the real arm |
|---|---|---|
| `earthquake` | camera shake, platforms jitter | shake on pan/wrist, ≤3°, ≤5 s |
| `fog` | fog rolls in | follower lags up to 800 ms behind the leader |
| `mirror` | screen flips | shoulder pan inverted |
| `molasses` | slow motion | follower low-pass filtered, sluggish |
| `butterfingers` | warning icon | jaw cannot close past 18%, so a block may slip |
| `freeze` | arm turns to ice | holds its pose, ignoring the leader, ≤3 s |

`intensity` and `duration` are **clamped server-side** to per-effect caps, so a wrong number
from a game script cannot cook a servo. An unknown name gets an `error` frame and is ignored.
Sending `intensity: 0, duration: 0` effectively cancels an effect.

Safety is three independent layers plus a kill key: the caps above, `max_relative_target` on
the follower (per-tick jump, and so current), and the calibrated absolute joint ranges. The
space bar in the Python terminal clears every active effect instantly.

Note that after a `freeze` the leader has kept moving, so the follower snaps to catch up when
it ends. `max_relative_target` ramps that rather than letting it lurch.

### `mode`, `place`

```json
{"t":"mode","name":"obby","level":3}
```

Accepted and queued for the producer. `mode` is not interpreted yet. `place` is reserved for
the autonomous source (ask the arm to put a block somewhere) and is not implemented.

### `ping`

```json
{"t":"ping","id":7}
```

## Backpressure

The server sends 30 frames a second whether or not anything reads them. **A client that reads
slower than that will fall behind**, because frames queue in the socket rather than being
dropped. So a client must keep only the newest frame and apply it on its own clock — which is
what `roblox/Bridge.lua` does, storing the latest in `MessageReceived` and applying it on
`Heartbeat`. Discarding a frame is correct: the next one is always more current.
