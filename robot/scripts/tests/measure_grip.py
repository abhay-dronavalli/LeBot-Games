"""Print the follower's live jaw reading, so the grip thresholds are measured and not guessed.

    python -m robot.scripts.tests.measure_grip

Torque stays OFF: you open and close the jaw by hand. Watch the number while you:

  1. hold the jaw wide open          -> this is roughly GRIPPER_OPEN
  2. close it on a real cube         -> this is the holding band
  3. close it the whole way on air   -> this is GRIP_EMPTY_PCT

Nothing in bridge/ needs these numbers any more: `board.ReleaseTrigger` learns the jaw's
open/closed span at runtime from the readings it sees, precisely because a hardcoded
percentage is wrong for any other gripper and wrong again after a recalibration. This script
is still useful for checking the jaw by hand, and (3) only
matters if you want to tell an empty jaw from a holding one in your own code.

The running totals at the end give the min and max seen, which is usually all you need.
"""

import sys
import time

from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig

PORT = "COM7"
ROBOT_ID = "my_follower"
HZ = 10.0


def main():
    robot = SO101Follower(SO101FollowerConfig(port=PORT, id=ROBOT_ID))
    robot.bus.connect()
    lo, hi = None, None
    try:
        robot.bus.disable_torque()
        print("Torque is OFF - move the jaw by hand. Ctrl-C to stop.\n")
        print("  open it wide, then close it on a cube, then close it on air.\n")
        while True:
            q = robot.bus.sync_read("Present_Position")
            grip = float(q["gripper"])
            lo = grip if lo is None else min(lo, grip)
            hi = grip if hi is None else max(hi, grip)
            bar = "#" * int(max(0.0, min(grip, 60.0)) / 2)
            print(f"\r  gripper {grip:6.1f}%   min {lo:5.1f}  max {hi:5.1f}   {bar:<30}",
                  end="", flush=True)
            time.sleep(1.0 / HZ)
    except (KeyboardInterrupt, EOFError):
        print("\n")
    finally:
        robot.bus.disconnect(disable_torque=True)

    if lo is not None:
        print(f"Seen: {lo:.1f}% at the narrowest, {hi:.1f}% at the widest.")
        # The same 0.4/0.6 split board.ReleaseTrigger derives for itself, printed so the
        # jaw can be sanity-checked by eye against what the bridge will decide at runtime.
        print(f"The bridge will read closed below {lo + (hi - lo) * 0.4:.0f}% "
              f"and open above {lo + (hi - lo) * 0.6:.0f}%")
        print("(that is 70% of the way from closed to open, so a jaw on a cube reads 'closed')")
    return 0


if __name__ == "__main__":
    sys.exit(main())
