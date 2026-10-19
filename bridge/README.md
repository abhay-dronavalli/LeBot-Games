# bridge/

Gets the arm's motion and the table's state into Roblox, and Roblox's events back into the arm.

The wire format is [`../PROTOCOL.md`](../PROTOCOL.md). The Roblox side is
[`../roblox/`](../roblox/). The mock client is [`../viewer/`](../viewer/).

## Running

```bash
source ~/lerobot/.venv/Scripts/activate       # or use the venv's python directly

python -m bridge.main --source mock --open    # no hardware, no API key; opens the mock viewer
python -m bridge.main --source follower       # real arm, torque OFF, move it by hand
python -m bridge.main --source teleop         # leader drives the real follower
python -m bridge.main --source teleop --vision   # ...and the real camera + board reads
```

Then either open <http://localhost:8766> for the mock Roblox viewer, or point Roblox Studio at
`ws://localhost:8765`.

Press **space** in the terminal to clear every active effect. That is the kill key: it stops a
shake without stopping the run. `q` or Ctrl-C quits. The 12 V barrel jack is the hard stop.

## The board

**Blocks are not tracked.** A vision model is shown the overhead frame and asked, in words,
what is sitting in each printed cell. That is the whole of perception now.

The read happens **two seconds after the gripper opens**, and otherwise not at all. The board
can only change when the arm lets a block go, so a clock would spend nearly every call
confirming a board nobody touched and still be late on the one read that matters. The two
seconds are for the block to settle and the arm to get out of the camera's way.

Between reads the same board is republished unchanged. So:

- A block in the gripper is still reported in the cell it was last read in. It does not
  vanish, and a player standing on it is not dropped. It moves when the next read says so.
- `held` is always `false`. The field is still on the wire because `roblox/BlockSync.lua`
  reads it, but nothing sets it any more.
- `blocks_age` of thirty seconds is healthy, not a fault. Use `notes.board` to tell a quiet
  board from a broken one.

Needs `OPENAI_API_KEY` in the environment or in a `.env` at the repo root (gitignored).
`OPENAI_MODEL` overrides the model; the default is a vision-capable GPT-4o. A read costs about
1,700 tokens and takes 2–4 s.

`--board-poll S` adds a safety-net re-read every S seconds, off by default. Releases cover
every change the *arm* makes; a timer only helps when somebody moves a cube by hand, and each
tick costs an API call.

### When a read fails

Every outcome goes on the bus as the `board` note, which rides in every state frame to the
viewer and to Roblox. The distinction that matters is drawn from OpenAI's `error.code`,
because a 429 is *either* "slow down" or "you are out of credits" and only one of those clears
by waiting:

| `state` | Meaning | Who fixes it |
|---|---|---|
| `ok` / `reading` | Working. | — |
| `no_credits` | The account is empty. **Red banner in the viewer and in Roblox.** | Top the account up; the read retries on its own. |
| `no_key` | No `OPENAI_API_KEY`. Blocks stay empty all session. | Set it, restart. |
| `auth` | The key was rejected. | Check it, restart. |
| `rate_limit` | Throttled. Yellow banner. | Nobody; it retries in ~20 s. |
| `error` | Usually the camera. Yellow banner. | Retries in ~20 s. |

An empty account is the one failure that looks exactly like a working rig nobody has touched,
and the one a human can clear in a minute — hence the banner rather than a log line.

## Testing, in order

Each rung adds exactly one new thing, so a failure tells you what broke. Do not skip to
teleop: rungs 1–3 need no torque and catch most problems.

**1. No hardware, no API key.**

```bash
./run test                                    # both of the below, in order
python -m bridge.test_board                   # 13 scenarios: parsing, ids, stacking, trigger
python -m bridge.main --source mock --open    # then, in another terminal:
python -m bridge.test_link                    # end-to-end, headless stand-in for Roblox
```

`test_link` does exactly what a Roblox script does. If it passes, the only thing between here
and Studio is the Lua. The mock fakes the model as well as the hardware — it answers the same
question from what it already knows — so the trigger, the ids and the stacking all run for
real with nothing plugged in.

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

**4. The board.** Add `--vision` to rung 3. One read happens at startup, so blocks should
appear within a few seconds in the cells they are really in. Then:

- Open and close the jaw. Two seconds after it opens, the terminal should print a new read.
- Move a cube to another cell by hand, then open the jaw. The next read should follow it, and
  its id must not change.
- Stack one cube on another and release. Both should be reported, as level 0 and level 1. The
  buried one keeps its colour, which comes from memory, not from the camera.

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
into a `StateBus`; the broadcast task reads whatever is latest on its own clock. So a 3-second
model call cannot stall the arm, a stalled arm cannot stall the wire, and a client that stops
reading cannot stall either.

**The arm is continuous, the board is discrete.** The arm reads at 30 Hz and the wire runs at
30 Hz, but the board changes a few times a minute — once per release. Those are not two rates
of the same thing; they are two different kinds of fact, and `arm_age` and `blocks_age` let a
client treat them differently instead of assuming both should be fresh.

## Modules

| Module | Role |
|---|---|
| `main.py` | Starts the producer, the server and the kill key. The only entry point. |
| `protocol.py` | The wire format: frame builders, version, rates, ports. |
| `state.py` | `StateBus` (latest-value handoff between threads) and `Inbox` (frames from the client). |
| `board.py` | **The board: the model call, the release trigger, cells → mm, stable ids.** |
| `effects.py` | Roblox events as modifiers on the joint command, with hard safety caps. |
| `server.py` | The WebSocket server, plus a tiny HTTP server for the viewer and `GET /state`. |
| `producers/arm.py` | One joint reading → one wire-shaped arm frame. Shared by all producers. |
| `producers/mock.py` | The whole rig faked, through the real IK, including the board reads. |
| `producers/teleop.py` | Leader → follower, with effects applied and real positions published. |
| `producers/board.py` | Watches the gripper, reads the board on release, reports failures. |

### What `board.py` replaced

It replaced `world.py`, which was ~700 lines of frame-to-frame tracking, and the segmentation
pipeline it was fed by. That machinery existed almost entirely to answer one question — *where
is the block while the arm is carrying it* — which the game does not need. A block matters
where it comes to rest, and the only resting places are the twelve printed cells.

Gone with it: homography fitting for blocks, colour segmentation, cube-outline fitting,
nearest-neighbour association and its gates, runtime grip-range learning, grab confirmation,
phantom-carry detection, occlusion memory, EMA smoothing and deadbanding, and cell snapping —
all of which are moot once the answer is a cell label rather than a measurement in millimetres.

Three things survived, because they were load-bearing rather than inferential:

- **Stable ids**, so one real block is one Roblox platform across reads. `Board._identify`
  matches a fresh reading to the previous one by cell, then level, then colour.
- **The open-jaw edge**, learned from the gripper's observed range rather than a fixed
  percentage. `world.py` was burned by a hardcoded threshold; here getting it wrong would mean
  the board is read once at startup and never again.
- **One line of memory**: a buried cube's colour. An overhead camera genuinely cannot see the
  colour of a block with another block on top of it, so the model says `unknown` and `Board`
  fills it in from the last read.

Note that `robot/perception/` is untouched and still carries the full segmentation pipeline.
The robot's own autonomous pick-and-place (`robot/executor.py`) and every calibration script
depend on it. Only the *bridge* stopped using it.

## Things to know before the demo

- **The sheet must be the labelled one.** The model reads the printed `A1`…`C4` labels to
  decide which cell a cube is in. That is `robot/assets/grid_sheet_3x4.print.html`. On an
  unlabelled sheet it falls back to guessing from position, which is much worse.
- **The AprilTags no longer matter to the bridge.** Nothing in `bridge/` fits a homography any
  more. They are still used by `robot/` for the arm's own calibration and autonomous mode.
- **Credits.** A read is cheap, but the board stops dead when the account empties. The banner
  says so; see the table above.
- **The servo bus dropout.** This rig loses the bus under motion current after 37–220 s (see
  `robot/teleop_monitored.py`). `producers/teleop.py` retries instead of exiting and leaves the
  WebSocket up, so Roblox holds its last pose and `arm_age` climbs. It is not fixed, only
  survived.
