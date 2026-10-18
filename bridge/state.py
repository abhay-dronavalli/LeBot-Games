"""The handoff between threads.

Only one process can hold the follower's COM port, so the arm loop, the vision loop and the
WebSocket server all live in one process. They are different rates (arm 30 Hz, vision ~10 Hz,
wire 30 Hz), so they do not call each other: producers publish into a StateBus and the server
reads whatever is latest. A slow camera frame can never stall the arm, and a stalled arm can
never stall the wire.

Nothing here blocks for longer than a dict copy.
"""

import threading
import time


class StateBus:
    """Latest-value store. Producers call publish_*(); the server calls snapshot()."""

    def __init__(self):
        self._lock = threading.Lock()
        self._arm = None          # {"joints": {...}, "points": [...], "tip": {...}, ...}
        self._arm_ts = 0.0
        self._blocks = []         # [{"id", "color", "x", "y", "z", "yaw", ...}]
        self._blocks_ts = 0.0
        self._notes = {}          # free-form: fit error, dropped frames, servo temps
        self._seq = 0

    def publish_arm(self, arm):
        with self._lock:
            self._arm = arm
            self._arm_ts = time.time()

    def publish_blocks(self, blocks):
        with self._lock:
            self._blocks = blocks
            self._blocks_ts = time.time()

    def arm(self):
        """The latest arm frame, without taking a snapshot. The vision thread needs the arm
        pose to decide what is held, and snapshot() bumps the sequence number, which must
        count broadcast frames only."""
        with self._lock:
            return self._arm

    def note(self, key, value):
        """A diagnostic that rides along with the state frame (voltage, tag fit error...)."""
        with self._lock:
            self._notes[key] = value

    def snapshot(self, effects=None):
        """One state frame. Ages let the client grey out stale parts instead of trusting them."""
        now = time.time()
        with self._lock:
            self._seq += 1
            return {
                "t": "state",
                "seq": self._seq,
                "ts": now,
                "arm": self._arm,
                "arm_age": round(now - self._arm_ts, 3) if self._arm_ts else None,
                "blocks": self._blocks,
                "blocks_age": round(now - self._blocks_ts, 3) if self._blocks_ts else None,
                "effects": effects or [],
                "notes": dict(self._notes),
            }


class Inbox:
    """Frames arriving from the client. The server appends; producers drain on their own tick.

    Producers must not touch the event loop, so this is a plain lock-protected list rather
    than an asyncio.Queue.
    """

    def __init__(self, limit=256):
        self._lock = threading.Lock()
        self._items = []
        self._limit = limit

    def put(self, frame):
        with self._lock:
            self._items.append(frame)
            if len(self._items) > self._limit:
                del self._items[: len(self._items) - self._limit]

    def drain(self, kinds=None):
        """Take and return pending frames, optionally only those whose "t" is in `kinds`."""
        with self._lock:
            if kinds is None:
                out, self._items = self._items, []
                return out
            out = [f for f in self._items if f.get("t") in kinds]
            self._items = [f for f in self._items if f.get("t") not in kinds]
            return out
