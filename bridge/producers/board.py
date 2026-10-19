"""The camera thread: watch the gripper, read the board when it lets go.

Replaces `producers/vision.py`, which ran a homography fit plus colour segmentation over a
1920x1080 frame ten times a second and fed the result into a 700-line tracker. Nothing here
runs continuously but a cheap poll of the arm's gripper reading. A board read happens when
the jaw opens and not otherwise, so the usual cost of this thread is zero.

    board = Board()
    start(bus, board, stop)

Three things it owns:

**The trigger.** `ReleaseTrigger` fires two seconds after the jaw opens, plus once at startup
so the game does not begin with an empty board. A read in flight does not block the next
trigger: open the jaw again and another read is queued behind this one.

**Republishing.** The server sends 30 state frames a second and wants a block list in every
one of them, but a read happens a few times a minute. So the thread republishes the same
board on a slow tick, which is what keeps `blocks_age` meaningful rather than letting it
climb for minutes at a time.

**Saying what went wrong.** A board that stops updating looks identical from Roblox whether
the camera died, the network dropped, or the OpenAI account ran out of credits - and the last
of those is the one a human can actually fix, mid-demo, in about a minute. So every read's
outcome goes on the bus as the `board` note, which rides along in every state frame to the
viewer and to Roblox. See `bridge/board.BoardUnavailable.kind`.
"""

import threading
import time

from .. import board as board_mod
from ..board import Board, BoardUnavailable, ReleaseTrigger

POLL_HZ = 20.0              # how often the gripper is checked for an open edge
REPUBLISH_S = 0.5           # keep blocks_age honest between reads
RETRY_S = 20.0              # after a read that failed for a reason that may pass

# The running thread's trigger, so something outside it can ask for a read. Releases cover
# every change the arm makes, but a cube moved by *hand* never opens the jaw and so is
# invisible until the next grab - which during a demo is the moment someone is pointing at
# the board asking why Roblox disagrees with it. `--board-poll` is the automatic answer;
# this is the manual one, wired to a key in bridge/main.py.
_live_trigger = None


def request_now():
    """Ask the board thread to read on its next tick. Returns False if no thread is running
    (mock mode, or no --vision), so the caller can say so rather than look like it worked."""
    trigger = _live_trigger
    if trigger is None:
        return False
    trigger.request(time.time())
    return True


def _note(bus, state, board, trigger, message=None, extra=None):
    """The `board` note: everything a UI needs to explain the board's condition in words."""
    note = {
        "state": state,                     # ok | reading | waiting | error | no_credits | ...
        "model": board_mod.model_name(),
        "reads": board.reads,
        "cells": board.summary(),
        "since_read": None if not board.read_at() else round(time.time() - board.read_at(), 1),
        "trigger": f"{trigger.delay_s:g} s after the gripper opens",
    }
    if message:
        note["message"] = message
    if state == "no_credits":
        # The one failure a human fixes rather than waits out, so it carries the fix with it.
        note["fix"] = "add credits to the OpenAI account"
        note["url"] = board_mod.BILLING_URL
    if board.clamped:
        note["clamped"] = board.clamped
    if extra:
        note.update(extra)
    bus.note("board", note)


def run(bus, board, stop, poll_hz=POLL_HZ, trigger=None, poll_s=None):
    """Thread body. `poll_s`, if given, is a safety-net re-read interval (`--board-poll`).

    The camera is opened here rather than passed in: this thread is the only thing that reads
    from it, and `Camera` keeps its own grabber thread so a frame is always fresh.
    """
    from robot.perception.camera import Camera

    global _live_trigger
    trigger = trigger or ReleaseTrigger()
    _live_trigger = trigger
    period = 1.0 / poll_hz
    published = 0.0
    said = None                             # the last fatal reason printed, so it prints once

    if not board_mod.available():
        print("  board: no OPENAI_API_KEY (environment, or a .env at the repo root).\n"
              "         The board cannot be read; blocks will stay empty.")
        _note(bus, "no_key", board, trigger,
              "no OPENAI_API_KEY (environment, or a .env at the repo root)")

    with Camera() as cam:
        print(f"  board: camera open, reading {trigger.delay_s:g} s after each release "
              f"({board_mod.model_name()})")
        trigger.request(time.time())        # one read at startup, so the board starts populated
        while not stop.is_set():
            loop = time.perf_counter()
            now = time.time()

            arm = bus.arm()
            trigger.feed((arm or {}).get("joints", {}).get("gripper"), now)
            # The safety net, off by default. Releases cover every change the *arm* makes, but
            # nothing fires when a cube is moved by hand, so --board-poll re-reads on a timer
            # as well. It asks for a read only when none is already pending, so it never
            # queues up behind a release.
            if poll_s and trigger.pending_at() is None and now - board.read_at() >= poll_s:
                trigger.request(now)

            if trigger.due(now):
                _note(bus, "reading", board, trigger)
                try:
                    readings = board_mod.read_board(cam.read())
                except BoardUnavailable as e:
                    _note(bus, e.kind, board, trigger, str(e))
                    if e.kind != said:
                        said = e.kind
                        if e.kind == "no_credits":
                            print("\n  !! board: the OpenAI account is out of credits. The "
                                  "board has stopped updating.\n"
                                  f"     Add credits at {board_mod.BILLING_URL} - the read "
                                  "retries on its own once you do.\n")
                        else:
                            print(f"  board: read failed ({e.kind}): {e}")
                    if not stop.is_set() and e.kind != "no_key":
                        # Retry on a timer. A rate limit or a dropped network clears on its
                        # own; an empty account clears the moment somebody tops it up, and
                        # there may be no further release to trigger a retry.
                        trigger.request(now, RETRY_S)
                except Exception as e:                      # a camera fault, not a model one
                    _note(bus, "error", board, trigger, f"{type(e).__name__}: {e}")
                    print(f"  board: {type(e).__name__}: {e}")
                    trigger.request(now, RETRY_S)
                else:
                    said = None
                    blocks = board.apply(readings, time.time())
                    bus.publish_blocks(blocks)
                    published = loop
                    last = getattr(board_mod.read_board, "last", {})
                    _note(bus, "ok", board, trigger,
                          extra={"seconds": last.get("seconds"),
                                 "tokens": last.get("tokens")})
                    print(f"  board: read {board.reads} in {last.get('seconds', '?')}s -> "
                          f"{len(blocks)} block(s): {board.summary()}")

            # The wire wants a block list in every frame; a read produces one a few times a
            # minute. Republishing the same board is what keeps blocks_age a measure of the
            # link rather than a measure of how long since anyone moved a cube.
            if loop - published >= REPUBLISH_S:
                bus.publish_blocks(board.blocks())
                published = loop

            sleep = period - (time.perf_counter() - loop)
            if sleep > 0:
                time.sleep(sleep)

    _live_trigger = None     # the thread is going away; a manual request would go nowhere


def start(bus, board, stop, poll_hz=POLL_HZ, poll_s=None):
    t = threading.Thread(target=run, args=(bus, board, stop),
                         kwargs={"poll_hz": poll_hz, "poll_s": poll_s},
                         name="board", daemon=True)
    t.start()
    return t
