"""Leader -> follower teleop with power telemetry, to catch the mid-run bus dropout.

Stock lerobot-teleoperate dies after 37-220 s with "no status packet" on all six
follower IDs. At idle the follower reads 11.8-12.0 V and 31-35 C, so the fault only
shows under motion current. Only one process can hold COM7, so the monitoring has
to live inside the teleop loop.

    python -m robot.teleop_monitored                 # 60 s, ramped, telemetry each 0.5 s
    python -m robot.teleop_monitored --seconds 180
    python -m robot.teleop_monitored --max-step 5    # tighter current limit
    python -m robot.teleop_monitored --no-limit      # match stock teleop (no clamp)

Ctrl-C stops and drops torque.
"""

import argparse
import csv
import time
from pathlib import Path

from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig
from lerobot.teleoperators.so_leader import SO101Leader, SO101LeaderConfig

FOLLOWER_PORT = "COM7"
LEADER_PORT = "COM5"
MAX_GOAL_ERROR = 2.0      # deg; goal must match present before torque goes on
TELEMETRY_EVERY = 0.5     # seconds
JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

# Status register (65) error bits. LED_Alarm_Condition=47 means the servo blinks its
# LED on any of these; Unloading_Condition=44 means overheat/current/overload also
# make the servo drop its own torque.
STATUS_BITS = [
    (0x01, "voltage"),
    (0x02, "angle/sensor"),
    (0x04, "overheat"),
    (0x08, "overcurrent"),
    (0x20, "overload"),
]


def decode_status(val):
    if val == 0:
        return "ok"
    names = [n for bit, n in STATUS_BITS if val & bit]
    extra = val & ~sum(bit for bit, _ in STATUS_BITS)
    if extra:
        names.append(f"unknown bit 0x{extra:02x}")
    return "+".join(names) if names else f"0x{val:02x}"


def read_health(bus):
    """Voltage (0.1 V units), current (raw), temperature (C). Returns None on bus error."""
    try:
        return {
            "volt": bus.sync_read("Present_Voltage", num_retry=2),
            "curr": bus.sync_read("Present_Current", num_retry=2),
            "temp": bus.sync_read("Present_Temperature", num_retry=2),
            "stat": bus.sync_read("Status", normalize=False, num_retry=2),
            "load": bus.sync_read("Present_Load", normalize=False, num_retry=2),
        }
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--max-step", type=float, default=10.0,
                    help="max_relative_target in deg; limits per-tick jump and so current")
    ap.add_argument("--no-limit", action="store_true", help="no clamp, like stock teleop")
    ap.add_argument("--log", default=None,
                    help="default: robot/outputs/teleop_health_<timestamp>.csv (one per run)")
    args = ap.parse_args()

    limit = None if args.no_limit else args.max_step
    follower = SO101Follower(SO101FollowerConfig(
        port=FOLLOWER_PORT, id="my_follower", max_relative_target=limit))
    leader = SO101Leader(SO101LeaderConfig(port=LEADER_PORT, id="my_leader"))

    log_path = Path(args.log) if args.log else Path(
        f"robot/outputs/teleop_health_{time.strftime('%Y%m%d_%H%M%S')}.csv")
    log_path.parent.mkdir(parents=True, exist_ok=True)

    leader.connect(calibrate=False)
    follower.bus.connect()
    torque_on = False
    fail_reason = None
    last_health = None
    worst_volt = 999
    worst_temp = 0
    ticks = 0
    corrupt = []
    alarms = []

    try:
        if not follower.bus.is_calibrated:
            raise SystemExit("Follower motors don't match the calibration file.")

        # Stale Goal_Position gotcha: sync goal to present before torque on.
        follower.bus.disable_torque()
        present = follower.bus.sync_read("Present_Position")
        follower.bus.sync_write("Goal_Position", present)
        goal = follower.bus.sync_read("Goal_Position")
        worst = max(abs(goal[m] - present[m]) for m in present)
        if worst > MAX_GOAL_ERROR:
            raise SystemExit(f"Goal/present mismatch {worst:.1f} deg; not enabling torque.")
        print(f"Goal synced to present (max error {worst:.2f} deg).")

        lead = leader.get_action()
        gaps = {j: abs(lead[f"{j}.pos"] - present[j]) for j in JOINTS}
        print("\nStart gap leader vs follower (deg):")
        for j in JOINTS:
            flag = "  <-- large" if gaps[j] > 20 else ""
            print(f"  {j:16s} {gaps[j]:7.2f}{flag}")
        if max(gaps.values()) > 20:
            input("\nLarge gap: the follower will swing to catch up. ENTER to continue, Ctrl-C to abort...")

        h = read_health(follower.bus)
        if h:
            print(f"\nIdle: {[v/10 for v in h['volt'].values()]} V, {list(h['temp'].values())} C")

        follower.configure()
        torque_on = True
        print(f"\nTeleop running: {args.fps:.0f} Hz, {args.seconds:.0f} s, "
              f"max_step={'none' if limit is None else f'{limit} deg'}. Ctrl-C to stop.\n")

        fh = open(log_path, "w", newline="")
        writer = csv.writer(fh)
        writer.writerow(["t", "tick"] + [f"v_{j}" for j in JOINTS]
                        + [f"i_{j}" for j in JOINTS] + [f"c_{j}" for j in JOINTS]
                        + [f"s_{j}" for j in JOINTS] + [f"l_{j}" for j in JOINTS])

        t0 = time.perf_counter()
        next_tel = 0.0
        period = 1.0 / args.fps
        while True:
            loop_start = time.perf_counter()
            elapsed = loop_start - t0
            if elapsed >= args.seconds:
                break

            action = leader.get_action()
            follower.send_action(action)
            ticks += 1

            if elapsed >= next_tel:
                next_tel = elapsed + TELEMETRY_EVERY
                h = read_health(follower.bus)
                if h is None:
                    fail_reason = "telemetry read failed - bus stopped answering"
                    break
                last_health = h
                volts = [v / 10 for v in h["volt"].values()]
                temps = list(h["temp"].values())
                # A motor cannot change tens of degrees in 0.5 s, and >70 C is past
                # the shutdown limit: implausible values are corrupted bus bytes.
                for j in JOINTS:
                    t, v = h["temp"][j], h["volt"][j] / 10
                    if not (0 < t <= 70) or not (9.0 < v < 13.5):
                        corrupt.append((elapsed, j, t, v))
                worst_volt = min(worst_volt, min(volts))
                worst_temp = max(worst_temp, max(temps))
                writer.writerow([f"{elapsed:.2f}", ticks]
                                + list(h["volt"].values()) + list(h["curr"].values()) + temps
                                + list(h["stat"].values()) + list(h["load"].values()))
                for j in JOINTS:
                    if h["stat"][j]:
                        alarms.append((elapsed, j, h["stat"][j], h["load"][j]))
                        print(f"  !! {elapsed:6.1f}s {j} ALARM: "
                              f"{decode_status(h['stat'][j])} (load={h['load'][j]})")
                fh.flush()
                sag = "  *** SAG ***" if min(volts) < 10.5 else ""
                print(f"  {elapsed:6.1f}s  {min(volts):5.2f}-{max(volts):5.2f} V  "
                      f"max {max(temps):2d} C  I={max(h['curr'].values()):5d}{sag}")

            sleep = period - (time.perf_counter() - loop_start)
            if sleep > 0:
                time.sleep(sleep)

        fh.close()

    except KeyboardInterrupt:
        print("\nStopped by Ctrl-C.")
    except Exception as e:
        fail_reason = f"{type(e).__name__}: {e}"
    finally:
        elapsed = time.perf_counter() - t0 if ticks else 0
        print(f"\n--- ran {elapsed:.1f} s, {ticks} ticks ---")
        print(f"lowest voltage seen: {worst_volt:.2f} V    highest temp: {worst_temp} C")
        if alarms:
            print(f"\n  SERVO ALARMS: {len(alarms)} sample(s) with a non-zero Status register")
            seen = {}
            for el, j, st, ld in alarms:
                seen.setdefault((j, st), []).append((el, ld))
            for (j, st), hits in seen.items():
                print(f"  {j:16s} {decode_status(st):28s} {len(hits)}x, first at {hits[0][0]:.1f}s, "
                      f"load={hits[0][1]}")
            print("  This is what makes the LED blink. Unloading_Condition=44, so overheat/")
            print("  overcurrent/overload also make that servo drop its own torque.")
        else:
            print("no servo alarms - all Status registers stayed 0")
        if corrupt:
            print(f"\n  BUS CORRUPTION: {len(corrupt)} implausible reading(s) -- garbled bytes")
            for el, j, t, v in corrupt[:10]:
                print(f"  {el:6.1f}s  {j:16s} temp={t} C  volt={v:.1f} V")
            print("  Voltage/current normal + garbled reads => signal integrity (cable/connector),")
            print("  not power. Same root cause as 'no status packet', milder.")
        else:
            print("no corrupted readings - bus clean this run")
        if not fail_reason and ticks:
            print(f"Reached the {args.seconds:.0f} s limit - normal stop. Torque drops, so the")
            print("arm goes limp. Use --seconds N for longer, or Ctrl-C when you are done.")
        if fail_reason:
            print(f"FAILED: {fail_reason}")
            if last_health:
                print("last good telemetry before the drop:")
                for j in JOINTS:
                    print(f"  {j:16s} {last_health['volt'][j]/10:5.2f} V  "
                          f"{last_health['temp'][j]:2d} C  I={last_health['curr'][j]}")
            print("\nVoltage at/below ~10.5 V under load => supply browning out.")
            print("Voltage fine but bus dead => connector/wiring, not power.")
        print(f"log: {log_path}")
        try:
            leader.disconnect()
        except Exception:
            pass
        try:
            follower.bus.disconnect(disable_torque=True)
            print("Follower disconnected, torque off.")
        except Exception as e:
            print(f"Clean disconnect failed ({e}) - unplug the 12V barrel jack to drop torque.")


if __name__ == "__main__":
    main()
