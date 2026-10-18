"""Start the bridge: one producer thread, an optional board thread, and the WebSocket server.

    python -m bridge.main --source mock              # no hardware, no API key
    python -m bridge.main --source teleop            # leader -> follower, real arm
    python -m bridge.main --source teleop --vision   # ...and the real camera + board reads
    python -m bridge.main --source mock --open       # mock + open the viewer in a browser

Then open http://localhost:8766 for the mock Roblox viewer, or point Roblox Studio at
ws://localhost:8765 (the laptop's LAN IP if Studio is on a different machine).

Press the space bar in this terminal to clear every active effect. That is the kill key: it
stops a shake immediately without stopping the run.

With `--vision`, the board is read by a vision model two seconds after the gripper opens, and
not otherwise - the board can only change when the arm lets a block go. That needs
OPENAI_API_KEY in the environment or in a `.env` at the repo root. See `bridge/board.py`.
"""

import argparse
import asyncio
import signal
import threading
import time
import webbrowser

from robot.perception.config import CUBE_SIZE_MM, SHEET_H_MM, SHEET_W_MM
from robot.workspace import Workspace

from . import board as board_mod
from . import protocol, server
from .board import Board
from .effects import EffectStack
from .state import Inbox, StateBus



def _grid():
    """The grid straight from the spec, so regenerating the sheet needs no edit here."""
    import json
    from robot.perception.config import SHEET_SPEC
    g = json.loads(SHEET_SPEC.read_text())["grid"]
    return g

# A suggested mapping, not a rule: the client converts mm to its own units, so these can be
# retuned in Roblox without restarting Python.
#
# The two numbers are deliberately independent. Scaling height by the same factor as xy would
# make a 48 mm cube 22 studs tall, far above the ~7-stud default jump, so no stack would ever
# be climbable. Instead xy is scaled to make the sheet a playable build zone, and one stack
# level is worth a jumpable step. That is plan.md's scale rule: one block = one jumpable step,
# a three-block wall = not jumpable.
SUGGEST_STUDS_PER_MM = 0.46                # sheet becomes about 99 x 129 studs
SUGGEST_LEVEL_STUDS = 6.5                  # one stack level, just under the default jump


def space(ws):
    """The static geometry the client needs to map sheet mm into its own world."""
    base = ws.base_sheet_xy()
    return {
        "frame": "sheet mm: origin at the sheet's top-left corner, +x right, +y down the "
                 "page (away from the arm), +z up off the paper",
        "sheet": {"w_mm": SHEET_W_MM, "h_mm": SHEET_H_MM},
        "grid": _grid(),
        "cube_mm": CUBE_SIZE_MM,
        "arm_base_mm": [round(float(base[0]), 1), round(float(base[1]), 1)],
        "suggest": {"studs_per_mm": SUGGEST_STUDS_PER_MM, "level_studs": SUGGEST_LEVEL_STUDS},
    }


def board_facts(args):
    """How the board is read, for the hello frame.

    A client needs this to tell "nobody has moved a block for half a minute" from "the link
    is broken". Blocks used to arrive ten times a second, so any age was a fault; now the
    board is read on release, and a block list that is 40 seconds old is perfectly healthy.
    """
    if args.source == "mock":
        return {"reader": "mock", "trigger": "release",
                "release_delay_s": board_mod.RELEASE_DELAY_S,
                "max_stack": board_mod.MAX_STACK, "cells": board_mod.cells()}
    if not args.vision:
        return {"reader": None, "trigger": None, "note": "no --vision: no blocks are read"}
    return {"reader": board_mod.model_name(), "trigger": "release",
            "release_delay_s": board_mod.RELEASE_DELAY_S,
            "poll_s": args.board_poll or None,
            "max_stack": board_mod.MAX_STACK, "cells": board_mod.cells()}


def kill_key(effects, stop):
    """The terminal's keys. Windows only (msvcrt); skipped silently elsewhere.

        space   clear all effects (the kill key)
        v       read the board now, without waiting for a release
        q       quit
    """
    try:
        import msvcrt
    except ImportError:
        return
    from .producers import board as board_producer

    while not stop.is_set():
        if msvcrt.kbhit():
            key = msvcrt.getch()
            if key in (b" ",):
                effects.clear()
                print("  [space] all effects cleared")
            elif key in (b"v", b"V"):
                # A cube moved by hand never opens the jaw, so no release fires and the board
                # keeps reporting where things used to be. This is the manual way out of that.
                if board_producer.request_now():
                    print("  [v] board read requested")
                else:
                    print("  [v] no board thread: mock mode, or started without --vision")
            elif key in (b"q", b"\x03"):
                stop.set()
        time.sleep(0.05)


def start_producer(args, bus, board, inbox, effects, stop):
    if args.source == "mock":
        from .producers import mock
        return threading.Thread(target=mock.run, name="mock",
                                args=(bus, board, inbox, effects, stop),
                                kwargs={"hz": args.arm_hz}, daemon=True)
    if args.source == "follower":
        from .producers import teleop
        return threading.Thread(target=teleop.run_passive, name="passive",
                                args=(bus, board, inbox, effects, stop),
                                kwargs={"hz": args.arm_hz, "vision": args.vision,
                                        "board_poll": args.board_poll}, daemon=True)
    if args.source == "teleop":
        from .producers import teleop
        return threading.Thread(target=teleop.run, name="teleop",
                                args=(bus, board, inbox, effects, stop),
                                kwargs={"hz": args.arm_hz, "vision": args.vision,
                                        "actual": args.actual,
                                        "board_poll": args.board_poll}, daemon=True)
    raise SystemExit(f"source {args.source!r} is not implemented yet")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--source", default="mock", choices=["mock", "follower", "teleop"],
                    help="mock: no hardware. follower: passive, torque off, move the arm by "
                         "hand. teleop: leader drives the real follower.")
    ap.add_argument("--vision", action="store_true",
                    help="run the real overhead camera and read the board with a vision model "
                         "(ignored by --source mock, which fakes both)")
    ap.add_argument("--board-poll", type=float, default=0.0, metavar="S",
                    help="also re-read the board every S seconds. Off by default: a release "
                         "covers every change the arm makes, so a timer only helps when "
                         "blocks are moved by hand. Each read costs an API call.")
    ap.add_argument("--actual", action="store_true",
                    help="teleop: also read true joint positions (an extra bus read at 5 Hz; "
                         "by default the published pose is the command actually sent, which "
                         "is free)")
    ap.add_argument("--arm-hz", type=float, default=protocol.ARM_HZ)
    ap.add_argument("--state-hz", type=float, default=protocol.STATE_HZ)
    ap.add_argument("--ws-port", type=int, default=protocol.WS_PORT)
    ap.add_argument("--viewer-port", type=int, default=protocol.VIEWER_PORT)
    ap.add_argument("--open", action="store_true", help="open the mock viewer in a browser")
    args = ap.parse_args()

    bus, inbox, effects = StateBus(), Inbox(), EffectStack()
    board = Board(cube_mm=CUBE_SIZE_MM or 48.0)
    stop = threading.Event()

    ws = Workspace()
    sp = space(ws)

    producer = start_producer(args, bus, board, inbox, effects, stop)
    producer.start()
    threading.Thread(target=kill_key, args=(effects, stop), name="killkey", daemon=True).start()

    server.viewer_server(bus, effects, args.viewer_port, args.ws_port)

    print(f"\n  source      {args.source}")
    print(f"  websocket   ws://localhost:{args.ws_port}   <- point Roblox Studio here")
    print(f"  viewer      http://localhost:{args.viewer_port}")
    print(f"  debug state http://localhost:{args.viewer_port}/state")
    print(f"  state rate  {args.state_hz:g} Hz    arm rate {args.arm_hz:g} Hz")
    if args.source == "mock":
        print("  board       faked by the mock, on the same release trigger")
    elif args.vision:
        print(f"  board       {board_mod.model_name()}, "
              f"{board_mod.RELEASE_DELAY_S:g} s after the gripper opens"
              + (f", and every {args.board_poll:g} s" if args.board_poll else ""))
        if not board_mod.available():
            print("              !! no OPENAI_API_KEY: put it in the environment or in a "
                  ".env at the repo root,\n"
                  "                 or the board will stay empty.")
    else:
        print("  board       not read (no --vision), so no blocks are published")
    print(f"  effects     {', '.join(sorted(effects.LIMITS))}")
    print("  space = clear effects,  v = read the board now,  q or Ctrl-C = quit\n")

    if args.open:
        webbrowser.open(f"http://localhost:{args.viewer_port}")

    async def run():
        loop = asyncio.get_running_loop()
        try:
            loop.add_signal_handler(signal.SIGINT, stop.set)
        except NotImplementedError:
            pass                        # Windows: KeyboardInterrupt below handles it
        await server.serve(bus, inbox, effects, sp, args.source, stop,
                           board=board_facts(args), ws_port=args.ws_port, hz=args.state_hz)

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        producer.join(timeout=3.0)
        print("\nstopped.")


if __name__ == "__main__":
    main()
