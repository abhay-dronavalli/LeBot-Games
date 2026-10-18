# bridge/

Gets the arm's motion and the table's state into Roblox, and Roblox's events back into the arm.

The wire format is [`../PROTOCOL.md`](../PROTOCOL.md). The Roblox side is
[`../roblox/`](../roblox/). The mock client is [`../viewer/`](../viewer/).

## Running

```bash
source ~/lerobot/.venv/Scripts/activate       # or use the venv's python directly

python -m bridge.main --source mock --open    # no hardware; opens the mock viewer
python -m bridge.main --source follower       # real arm, torque OFF, move it by hand
python -m bridge.main --source teleop         # leader drives the real follower
python -m bridge.main --source teleop --vision   # ...and the real overhead camera
```

Then either open <http://localhost:8766> for the mock Roblox viewer, or point Roblox Studio at
`ws://localhost:8765`.

Press **space** in the terminal to clear every active effect. That is the kill key: it stops a
shake without stopping the run. `q` or Ctrl-C quits. The 12 V barrel jack is the hard stop.

## Testing, in order

Each rung adds exactly one new thing, so a failure tells you what broke. Do not skip to
teleop: rungs 1-3 need no torque and catch most problems.

**1. No hardware at all.**

```bash
python -m bridge.test_world                   # the block tracker, 5 scripted scenarios
python -m bridge.main --source mock --open    # then, in another terminal:
python -m bridge.test_link                    # end-to-end, headless stand-in for Roblox
```

`test_link` does exactly what a Roblox script does. If it passes, the only thing between here
and Studio is the Lua. The mock viewer should show the arm running a pick-carry-stack cycle,
with one block going held (gold outline) and coming to rest at level 1.

**2. The protocol, from Roblox.** Still mock, so nothing can move. Paste `roblox/` into Studio
(see [`../roblox/README.md`](../roblox/README.md)) and press Play. The output window should
print `[Bridge] hello: source=mock protocol v1, 6 effects`. The Sky Arm should move.

**3. The real arm, torque off.** This is the important rung.

```bash
python -m bridge.main --source follower
```

Torque is disabled and nothing is ever commanded, so the arm cannot move on its own. Move it
by hand and watch the Sky Arm in the viewer. This tests the serial link, the follower
calibration, the FK, the sheet-frame transform and the wire — everything teleop uses *except*
motion. What to check:

- Lift the arm by hand: the viewer's tip height should rise, and `tip z` should read roughly
  the real height above the paper in mm.
- Touch the jaw tips to a known grid crossing: the tip xy should match that crossing's sheet
  mm within a few mm. If it is off by tens of mm, or the arm bends the wrong way,
  `robot/calibration/arm_sheet_calibration.json` is stale — re-run
  `robot.scripts.calibration.touch_calibrate`, not anything in here.
- Close the jaw on a cube by hand and read `gripper` off `GET /state`. **Write that number
  down**; it sets `world.GRIP_CLOSED_PCT` (see below).

**4. Blocks.** Add `--vision` to rung 3. Blocks should appear in the viewer at their real
positions. Slide one by hand: its id must not change. Pick one up by hand in front of the
camera: it should go `held` only if the jaw is genuinely closed on it.

**5. Teleop, no effects.**

```bash
python -m bridge.main --source teleop
```

**Before torque goes on, match the leader's pose to the follower's by hand.** The startup
check prints the gap per joint and warns above 20°; a large gap means the follower swings fast
to catch up. Keep a hand near the 12 V jack for the first run.

**6. Teleop plus effects.** With teleop running, click `earthquake` in the viewer, or from the
Studio command bar:

```lua
require(game.ServerScriptService.Bridge).sendEvent("earthquake", 0.7, 4)
```

The arm should wobble a few degrees for four seconds and stop on its own. Press **space** in
the Python terminal to cut it early. Try `freeze` next: the arm should hold its pose and
ignore the leader, then catch up when it expires.

## Why it is shaped this way

**One process, because the COM port says so.** Only one process can hold the follower's
serial port, so the WebSocket server must live inside whatever drives the arm. A separate
"robot reader" service is not an option, and that single constraint decides the architecture.

**No middle server.** Roblox Studio's `CreateWebStreamClient` connects *out*, so the robot
process is the server. A relay would only be needed for a published game, which this is not.

**Producers are threads, the server is asyncio.** They never call each other. Producers publish
into a `StateBus`; the broadcast task reads whatever is latest on its own clock. So a 150 ms
camera frame cannot stall the arm, a stalled arm cannot stall the wire, and a client that stops
reading cannot stall either.

**Three rates, on purpose.** The arm reads at 30 Hz, perception at ~10 Hz (it is a homography
fit plus colour segmentation over a 1920×1080 frame, nowhere near 30 Hz), and the wire runs at
30 Hz. The state frame carries `arm_age` and `blocks_age` so the client can tell how fresh each
half is instead of assuming.

## Modules

| Module | Role |
|---|---|
| `main.py` | Starts the producer, the server and the kill key. The only entry point. |
| `protocol.py` | The wire format: frame builders, version, rates, ports. |
| `state.py` | `StateBus` (latest-value handoff between threads) and `Inbox` (frames from the client). |
| `world.py` | **Stable block ids, held blocks and stack levels.** The real new logic here. |
| `effects.py` | Roblox events as modifiers on the joint command, with hard safety caps. |
| `server.py` | The WebSocket server, plus a tiny HTTP server for the viewer and `GET /state`. |
| `producers/arm.py` | One joint reading → one wire-shaped arm frame. Shared by all producers. |
| `producers/mock.py` | The whole rig faked, through the real IK. No hardware. |
| `producers/teleop.py` | Leader → follower, with effects applied and real positions published. |
| `producers/vision.py` | The overhead camera, in its own thread, feeding the tracker. |

### What `world.py` is for

`robot/perception/scene.py` is accurate (4.4 mm) but answers a different question than a game
needs. Per frame it reports which colourful blobs are on the sheet, which leaves two gaps a
Roblox `BlockSync` cannot live with:

- **No stable identity.** Blocks are named by colour, and two reds become `red_cube` and
  `red_cube_2` *in detection order*, which can swap between frames. One platform per block
  needs one persistent id per block.
- **No height.** Every block is mapped at mid-cube height on the paper, so a stacked block and
  a block on the table read identically — and a block in the gripper is not reported at all,
  because the jaw covers it.

`world.py` closes both by associating detections to tracks frame to frame and using the arm's
forward kinematics for what the camera cannot see:

- **Held:** a track that vanishes near the FK tip while the jaw is closed is held, not gone,
  and its position becomes the tip's. That is what gives the crane lift its height.
- **Released:** when the jaw opens, the block is free at the tip's xy, and its stack level is
  how many blocks already sit there. Occlusion memory: the camera never sees the lower block,
  the tracker remembers it.
- **Stack order** is arrival time at a spot, not block id, so the block just dropped lands on
  top.

## Things to measure before the demo

- **`world.GRIP_CLOSED_PCT` and `GRIP_EMPTY_PCT`.** Held-block detection keys off the gripper
  reading. The current 35 / 8 come from `robot/skills.py`'s `GRIPPER_OPEN = 50` and
  `MIN_GRASP = 8`, not from a measurement. Close the jaw on a real cube, read `gripper` out of
  `GET /state`, and set them.
- **Colour memory.** `producers/vision.py` runs `build_scene(naming="local")` so it never calls
  the vision model inside the loop. Build the colour memory with the calibration script first,
  or blocks arrive with guessed colours. Identity keys on position, so a wrong colour is only
  cosmetic.
- **The servo bus dropout.** This rig loses the bus under motion current after 37–220 s (see
  `robot/teleop_monitored.py`). `producers/teleop.py` retries instead of exiting and leaves the
  WebSocket up, so Roblox holds its last pose and `arm_age` climbs. It is not fixed, only
  survived.
