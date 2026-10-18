"""The real arm, in two modes.

    --source follower   passive. Torque off, nothing commanded. Reads where the arm is and
                        publishes it. You move the arm by hand and the Sky Arm follows.
                        No leader needed, nothing can run away. Test with this first.

    --source teleop     the real thing. Leader drives follower, effects bend the command on
                        the way through, and the result is published for the Sky Arm.

Passive mode exists because every part of the pipeline except torque is identical in both, so
it isolates "is the geometry right" from "is the arm safe to drive". If the Sky Arm tracks
your hand correctly in passive mode, the only thing teleop adds is motion.

Safety, in three independent layers, so a game script can never hurt the arm:

  1. `effects.py` caps every effect's amplitude and duration (3 deg, 5 s for a shake).
  2. `max_relative_target` on the follower limits the per-tick jump, and so the current.
  3. The calibrated joint ranges clamp the absolute command.

Plus the space-bar kill key in `bridge/main.py`, which clears all effects instantly.

Bus traffic. `send_action` already does its own `sync_read("Present_Position")` when
`max_relative_target` is set, and it *returns the clipped action it actually sent*. So the
published pose comes from that return value for free, rather than from a second
`get_observation()` read per tick. On this rig that matters: the servo bus drops out under
motion current after 37-220 s (see `robot/teleop_monitored.py`), and halving the traffic is
the cheapest thing that helps. Pass `--actual` to read true positions anyway, at a lower rate.

A dropout must not take the WebSocket down with it: Roblox keeps its last pose, `arm_age`
starts climbing so the client can grey the Sky Arm out, and the loop retries rather than
exiting.
"""

import time

from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
from lerobot.teleoperators.so_leader import SO101Leader, SO101LeaderConfig

from robot.workspace import Workspace, calibrated_ranges

from .arm import arm_frame, reading_from_action

FOLLOWER_PORT = "COM7"
LEADER_PORT = "COM5"
MAX_STEP_DEG = 10.0        # max_relative_target; teleop_monitored.py's default
MAX_GOAL_ERROR = 2.0       # goal must match present before torque goes on
BIG_GAP_DEG = 20.0         # leader this far from follower = it will swing to catch up
LIMIT_MARGIN_DEG = 3.0     # stay this far inside the calibrated hard stops
ACTUAL_HZ = 5.0            # --actual: rate for the extra true-position read
MAX_CONSECUTIVE_FAILS = 30


def clamp_to_ranges(action, ranges):
    """Absolute joint limits, applied after effects. An effect can shake the arm, but it can
    never shake it past a hard stop. The gripper is not in `ranges` and is left alone."""
    out = {}
    for key, value in action.items():
        half = ranges.get(key.removesuffix(".pos"))
        if half is None:
            out[key] = value
        else:
            lo, hi = -half + LIMIT_MARGIN_DEG, half - LIMIT_MARGIN_DEG
            out[key] = max(lo, min(float(value), hi))
    return out


def _publish(bus, tracker, ws, reading, extra, vision):
    arm = arm_frame(ws, reading, extra=extra)
    bus.publish_arm(arm)
    if vision:
        # The camera thread owns association and ageing at VISION_HZ. Here, at the much faster
        # ARM_HZ, only the held block is advanced - it is rigid in the jaw, so forward
        # kinematics already knows where it is and waiting for the next camera frame only adds
        # lag to the one block the player is standing on.
        bus.publish_blocks(tracker.follow_tip(arm, time.time()))
    else:
        # No camera at all: the full tracker is the only thing running, and with no detections
        # it still carries a held block along the tip.
        bus.publish_blocks(tracker.update([], arm, time.time()))
    return arm


def run_passive(bus, tracker, inbox, effects, stop, hz=30.0, vision=False):
    """Read the follower with torque off. Move the arm by hand; nothing is commanded."""
    ws = Workspace()
    follower = SO101Follower(SO101FollowerConfig(port=FOLLOWER_PORT, id="my_follower"))

    vision_thread = None
    if vision:
        from . import vision as vision_mod
        vision_thread = vision_mod.start(bus, tracker, stop)

    follower.bus.connect()
    print("  passive: follower connected")
    try:
        follower.bus.disable_torque()
        print("  passive: TORQUE OFF. Move the arm by hand; the Sky Arm should follow.")
        print("           Nothing is commanded, so the arm cannot move on its own.")

        period = 1.0 / hz
        fails = 0
        while not stop.is_set():
            loop = time.perf_counter()
            inbox.drain({"event"})       # accept and ignore: nothing to apply with torque off
            try:
                obs = follower.get_observation()
                reading = reading_from_action(obs)
                if reading:
                    _publish(bus, tracker, ws, reading, {"mode": "passive", "torque": False},
                             vision)
                fails = 0
            except Exception as e:
                fails += 1
                bus.note("bus_error", f"{type(e).__name__}: {e}")
                if fails == 1:
                    print(f"  passive: bus error ({type(e).__name__}: {e}); retrying")
                if fails >= MAX_CONSECUTIVE_FAILS:
                    print("  passive: bus down. The WebSocket stays up.")
                    break
                time.sleep(0.05)

            sleep = period - (time.perf_counter() - loop)
            if sleep > 0:
                time.sleep(sleep)
    finally:
        try:
            follower.bus.disconnect(disable_torque=True)
            print("  passive: disconnected.")
        except Exception as e:
            print(f"  passive: disconnect failed ({e})")
        if vision_thread:
            vision_thread.join(timeout=2.0)


def run(bus, tracker, inbox, effects, stop, hz=30.0, vision=False, actual=False):
    """Leader drives follower. Effects bend the command. Torque goes on."""
    ws = Workspace()
    ranges = calibrated_ranges()

    follower = SO101Follower(SO101FollowerConfig(
        port=FOLLOWER_PORT, id="my_follower", max_relative_target=MAX_STEP_DEG))
    leader = SO101Leader(SO101LeaderConfig(port=LEADER_PORT, id="my_leader"))

    vision_thread = None
    if vision:
        from . import vision as vision_mod
        vision_thread = vision_mod.start(bus, tracker, stop)

    leader.connect(calibrate=False)
    follower.bus.connect()
    print("  teleop: leader and follower connected")

    try:
        if not follower.bus.is_calibrated:
            raise SystemExit("Follower motors do not match the calibration file.")

        # The stale-Goal_Position gotcha: sync goal to present before torque goes on, or the
        # arm snaps to wherever it was last commanded.
        follower.bus.disable_torque()
        present = follower.bus.sync_read("Present_Position")
        follower.bus.sync_write("Goal_Position", present)
        goal = follower.bus.sync_read("Goal_Position")
        worst = max(abs(goal[m] - present[m]) for m in present)
        if worst > MAX_GOAL_ERROR:
            raise SystemExit(f"Goal/present mismatch {worst:.1f} deg; not enabling torque.")
        print(f"  teleop: goal synced to present (max error {worst:.2f} deg)")

        gaps = {j: abs(leader.get_action()[f"{j}.pos"] - present[j]) for j in present}
        worst_j = max(gaps, key=gaps.get)
        if gaps[worst_j] > BIG_GAP_DEG:
            print(f"  teleop: WARNING leader and follower differ by {gaps[worst_j]:.0f} deg at "
                  f"{worst_j}. The follower will swing to catch up when torque goes on.")
            print("          Match the leader's pose to the follower by hand first, or expect "
                  "a fast move.")
        else:
            print(f"  teleop: leader matches follower within {gaps[worst_j]:.1f} deg")

        follower.configure()
        print(f"  teleop: TORQUE ON, {hz:g} Hz. Ctrl-C to stop, space to clear effects.")

        period = 1.0 / hz
        actual_period = 1.0 / ACTUAL_HZ
        next_actual = 0.0
        fails = 0
        while not stop.is_set():
            loop = time.perf_counter()

            for frame in inbox.drain({"event"}):
                got = effects.add(frame.get("name"), frame.get("intensity", 1.0),
                                  frame.get("duration", 3.0))
                if got:
                    print(f"  teleop: effect {frame['name']} {got[0]:.2f} for {got[1]:.1f} s")

            try:
                action = leader.get_action()
                action = effects.apply(action, loop)
                action = clamp_to_ranges(action, ranges)

                # send_action returns the action it actually sent, after its own
                # max_relative_target clipping. Publishing that costs no extra bus traffic.
                sent = follower.send_action(action)
                reading = reading_from_action(sent if sent else action)

                extra = {"mode": "teleop"}
                if actual and loop >= next_actual:
                    next_actual = loop + actual_period
                    obs = reading_from_action(follower.get_observation())
                    if obs:
                        extra["commanded"] = reading
                        reading = obs
                        extra["actual"] = True

                if reading:
                    _publish(bus, tracker, ws, reading, extra, vision)
                fails = 0
            except Exception as e:
                fails += 1
                bus.note("bus_error", f"{type(e).__name__}: {e}")
                if fails == 1:
                    print(f"  teleop: bus error ({type(e).__name__}: {e}); retrying")
                if fails >= MAX_CONSECUTIVE_FAILS:
                    print("  teleop: bus down, giving up on the arm. The WebSocket stays up.")
                    break
                time.sleep(0.05)

            sleep = period - (time.perf_counter() - loop)
            if sleep > 0:
                time.sleep(sleep)

    finally:
        try:
            leader.disconnect()
        except Exception:
            pass
        try:
            follower.bus.disconnect(disable_torque=True)
            print("  teleop: follower disconnected, torque off.")
        except Exception as e:
            print(f"  teleop: clean disconnect failed ({e}); unplug the 12V jack to drop torque.")
        if vision_thread:
            vision_thread.join(timeout=2.0)
