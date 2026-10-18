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

The sheet is US Letter, 279.4 × 215.9 mm landscape, with a 3×4 grid of 57.15 mm cells
labelled `A1`..`C4` — the letter is the row, `A` nearest the arm. Those labels are printed on
the sheet, and the vision model reads them to place a block, so **block positions are cell
labels first and millimetres second**: `x`/`y` are derived from `cell`, not measured.

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
 "board":{"reader":"gpt-4o","trigger":"release","release_delay_s":2.0,"poll_s":null,
          "max_stack":2,"cells":["A1","A2","A3","A4","B1","B2","B3","B4","C1","C2","C3","C4"]},
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

`board` says how the block list is produced, so a client can tell "nobody has moved a cube in
a while" from "the link is broken". `reader` is the model name (or `"mock"`, or `null` when
nothing is reading), `trigger` is `"release"`, `cells` is every cell label on this sheet, and
`max_stack` is how tall a stack can get. See `notes.board` under `state` for its health.

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
| `id` | Stable across reads. One platform per id. Not derived from colour. |
| `cell` | The printed cell it is sitting in, `"A1"`..`"C4"`. The authoritative position. |
| `color` | A name, for looks. `"grey"` means the colour could not be read (see below). |
| `x`, `y` | Sheet mm: the centre of `cell`. `z` is `level` times the cube size. |
| `yaw` | Always `0.0`. A block in a printed cell is square to it. |
| `level` | Stack level. 0 is on the paper, 1 is on top of another block. Max 1. |
| `held` | Always `false`. Kept for compatibility; nothing sets it any more. |
| `visible` | Always `true`. A block is on the board or it is not reported at all. |
| `age` | Seconds since the read that produced it. |

**Blocks are not tracked frame to frame.** A vision model is shown the overhead frame and
asked what is in each printed cell. That read happens **two seconds after the gripper opens**
and otherwise not at all, because the board can only change when the arm lets go. Between
reads the same board is republished unchanged.

Three consequences a client has to be built for:

- **A block in the gripper stays where it was.** It is not on the board — it is in the air —
  so the last read's answer stands until the next one. Its platform must not be deleted or
  moved mid-carry; it simply steps to its new cell at the next read. This is why `held` is
  gone: there is no carry to render.
- **`blocks_age` of thirty seconds is healthy.** It is no longer a staleness signal. Use
  `notes.board` to tell a quiet board from a broken one.
- **A stacked block's lower cube may report `"grey"`.** An overhead camera cannot see the
  colour of a block with another block on top of it. The server fills this in from the
  previous read where it can, and sends grey where it cannot.

`arm_age` is seconds since the arm was last read, and still means what it always did: on a bus
dropout it climbs, so grey the Sky Arm out rather than trusting a stale pose.

### `notes.board`

Free-form diagnostics otherwise (`script` in mock mode, `bus_error`), but `notes.board` is
worth depending on: it is how a client explains a board that has stopped moving.

```json
{"state":"no_credits","model":"gpt-4o","reads":7,"cells":"A1 red, C4 grey+teal",
 "since_read":41.2,"trigger":"2 s after the gripper opens",
 "message":"You exceeded your current quota",
 "fix":"add credits to the OpenAI account",
 "url":"https://platform.openai.com/settings/organization/billing"}
```

| `state` | Meaning |
|---|---|
| `ok` | The last read succeeded. |
| `reading` | A read is in flight. |
| `no_credits` | The OpenAI account is empty. **The board has stopped updating.** Retries on its own once topped up. |
| `no_key` | No API key on the robot laptop. Blocks stay empty for the session. |
| `auth` | The key was rejected. |
| `rate_limit` | Throttled. Clears by itself; retries in ~20 s. |
| `error` | Usually the camera. Retries in ~20 s. |

`no_credits` is the one worth interrupting a player for: the rig looks completely healthy and
a human standing next to it can fix it in about a minute. `roblox/BoardNotice.lua` puts it on
screen.

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
