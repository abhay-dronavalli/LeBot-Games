"""The board as a vision model reads it: which cell holds which blocks, and nothing more.

This replaces `bridge/world.py`, which was ~700 lines of frame-to-frame tracking. That module
answered a much harder question than the game needs. It followed a block *while the arm was
carrying it* - associating detections to tracks, learning the gripper's range at runtime,
telling a real grasp from a jaw that shut on air, remembering blocks hidden under other blocks
- because a block in flight has no cell, and the camera cannot see it anyway.

The game does not need any of that. A block only matters where it comes to rest, and the only
resting places are the printed cells. So:

  * **One question, asked in words.** The frame goes to a vision model, which reads the cell
    labels printed on the sheet (A1..C4) and says what is sitting in each one. No homography,
    no colour segmentation, no cube-outline fit, no association gates, no AprilTags.
  * **Asked only when the answer can have changed.** The board changes when the gripper lets
    go, so the read is triggered by the jaw opening, not by a clock. See `ReleaseTrigger`.
  * **Nothing is tracked mid-carry.** A block in the jaw stays reported in the cell it was
    last read in, and moves when the next read says so. A platform never vanishes from under
    a player's feet, and there is no held state anywhere in the system.

What is kept from the old module is the one part that was genuinely load-bearing: **stable
ids**, so one real block is one Roblox platform across reads rather than a part destroyed and
rebuilt every time.

    board = Board()
    readings = read_board(frame)          # [{"cell": "B2", "color": "red", "level": 0}, ...]
    blocks = board.apply(readings, time.time())
"""

import base64
import json
import os
import re
import threading
import time
from pathlib import Path

from robot.perception.config import BLOCK_COLORS, CUBE_SIZE_MM, ROOT, SHEET_SPEC

CUBE_MM = CUBE_SIZE_MM or 48.0

# ---- the printed grid --------------------------------------------------------------
# Straight from the sheet spec, so regenerating the sheet moves the cells here with it.

_GRID = json.loads(Path(SHEET_SPEC).read_text())["grid"]
GRID_ORIGIN_MM = tuple(float(v) for v in _GRID["origin_mm"])
CELL_MM = float(_GRID["cell_mm"])
ROWS = [str(r) for r in _GRID["rows"]]          # letter is the row, A nearest the arm
COLS = [str(c) for c in _GRID["cols"]]

UNKNOWN_COLOR = "grey"                          # a block whose colour could not be read

# What the model says when it cannot see a colour. The prompt asks for "unknown", but the
# answer is prose from a language model, so accept the obvious neighbours. These all have to
# land on UNKNOWN_COLOR or `Board._identify` never recognises a buried block as needing its
# colour recovered from memory, and a stacked cube turns grey the moment something is put on
# top of it. `roblox/BlockSync.lua` has no entry for "unknown" either, so it would render as
# the default grey anyway - just without the memory that could have coloured it correctly.
UNNAMED = {"unknown", "unclear", "hidden", "obscured", "not visible", "n/a", "na", "none",
           "?", "unsure", "indeterminate", "grey", "gray"}

_CELL_RE = re.compile(r"\s*([A-Za-z]+)\s*0*(\d+)\s*")


def cells():
    """Every cell label on this sheet, "A1" .. "C4"."""
    return [f"{r}{c}" for r in ROWS for c in COLS]


def norm_cell(label):
    """Any spelling of a cell label -> "B2", or None if it is not one at all."""
    m = _CELL_RE.fullmatch(str(label))
    if m is None:
        return None
    row, col = m.group(1).upper(), m.group(2)
    return f"{row}{col}" if row in ROWS and col in COLS else None


def cell_centre(label):
    """"B2" -> its centre in sheet mm, or None if that is not a cell on this sheet."""
    cell = norm_cell(label)
    if cell is None:
        return None
    m = _CELL_RE.fullmatch(cell)
    r, c = ROWS.index(m.group(1)), COLS.index(m.group(2))
    return (GRID_ORIGIN_MM[0] + (c + 0.5) * CELL_MM,
            GRID_ORIGIN_MM[1] + (r + 0.5) * CELL_MM)


def cell_of(x, y):
    """Sheet mm -> the cell label containing it, or None when it is off the grid.

    Only the mock needs this (it knows where its fake blocks are in mm and has to answer in
    cells, as the model would). Nothing on the live path converts in this direction.
    """
    c = int((x - GRID_ORIGIN_MM[0]) // CELL_MM)
    r = int((y - GRID_ORIGIN_MM[1]) // CELL_MM)
    if 0 <= r < len(ROWS) and 0 <= c < len(COLS):
        return f"{ROWS[r]}{COLS[c]}"
    return None


def norm_color(name):
    """"Light_Blue" -> "light blue". Empty, or any way of saying "I cannot tell", -> grey."""
    c = re.sub(r"[\s_]+", " ", str(name or "")).strip().lower()
    return UNKNOWN_COLOR if (not c or c in UNNAMED) else c


# ---- when to ask ------------------------------------------------------------------

RELEASE_DELAY_S = 2.0           # after the jaw opens: let the block settle and the arm clear
GRIP_SPAN_MIN = 6.0             # the jaw's range must be this wide before it is worth trusting
GRIP_OPEN_PCT = 35.0            # fallback threshold until that range is known


class ReleaseTrigger:
    """Fires RELEASE_DELAY_S after the gripper opens, plus once at startup.

    The board can only change when the arm lets a block go, so that is the trigger - not a
    timer. A clock would spend nearly every call confirming a board nobody touched, and would
    still be up to a full period late on the one read that matters.

    The delay is why this is not simply "on open": at the instant the jaw parts, the block is
    still under the gripper and the arm is still in the camera's way. Two seconds later the
    block is sitting in its cell in clear view.

    Open and closed are judged against the jaw's *observed* range rather than a fixed
    percentage. An absolute threshold is a trap here - what counts as open depends on the
    gripper and on its calibration - and getting it wrong means `open` is never true and the
    board is never read again. Until the jaw has been seen both open and shut, fall back to
    the constant. (This is all that survives of `world.py`'s grip handling, and it is the one
    piece that was load-bearing rather than inferential.)
    """

    def __init__(self, delay_s=RELEASE_DELAY_S):
        self.delay_s = delay_s
        self.count = 0
        self._lo = None
        self._hi = None
        self._was_open = None
        self._fire_at = None

    def request(self, t, delay_s=0.0):
        """Ask for a read regardless of the jaw. Used for the first read of a session, and by
        `--board-poll` for the safety-net refresh."""
        at = t + delay_s
        if self._fire_at is None or at < self._fire_at:
            self._fire_at = at

    def feed(self, grip, t):
        """Call with the gripper reading on every tick. Arms a read on a closed->open edge."""
        if grip is None:
            return
        grip = float(grip)
        self._lo = grip if self._lo is None else min(self._lo, grip)
        self._hi = grip if self._hi is None else max(self._hi, grip)
        span = self._hi - self._lo
        if span >= GRIP_SPAN_MIN:
            is_open = grip >= self._lo + 0.6 * span
        else:
            is_open = grip >= GRIP_OPEN_PCT
        if is_open and self._was_open is False:
            self.request(t, self.delay_s)       # the jaw just let go
        self._was_open = is_open

    def due(self, t):
        """True once, when a read is owed. Clears the request."""
        if self._fire_at is not None and t >= self._fire_at:
            self._fire_at = None
            self.count += 1
            return True
        return False

    def pending_at(self):
        """When the next read is due, or None if none is pending."""
        return self._fire_at


# ---- the board --------------------------------------------------------------------


class Board:
    """The last board the model read, as the block list the protocol sends.

    `apply` is the whole of it: cells in, wire blocks out. The only thing worth keeping
    between reads is the id each block already had, so one real block stays one Roblox
    platform instead of being destroyed and rebuilt on every read.
    """

    def __init__(self, cube_mm=CUBE_MM):
        self.cube_mm = cube_mm
        self._lock = threading.RLock()
        self._blocks = []               # the last wire block list
        self._prev = []                 # [{"id", "color", "cell", "level"}]
        self._next_id = 1
        self._read_at = 0.0
        self.reads = 0
        self.clamped = []               # cells the model reported taller than MAX_STACK

    def apply(self, readings, t=None):
        """readings: [{"cell", "color", "level"}] from `read_board`, or from the mock.

        Returns the block list for the state frame. An empty list is a legitimate answer: it
        means the model saw a bare sheet.
        """
        t = time.time() if t is None else t
        with self._lock:
            entries = self._identify(self._clean(readings))
            self._prev = entries
            self._read_at = t
            self.reads += 1
            self._blocks = [self._to_json(e) for e in entries]
            return list(self._blocks)

    def blocks(self):
        """The last board, unchanged. What a producer republishes between reads."""
        with self._lock:
            return list(self._blocks)

    def read_at(self):
        with self._lock:
            return self._read_at

    def summary(self):
        """One short line for the terminal and the viewer: "A1 red, B2 teal+grey"."""
        with self._lock:
            by_cell = {}
            for e in sorted(self._prev, key=lambda e: (e["cell"], e["level"])):
                by_cell.setdefault(e["cell"], []).append(e["color"])
            return ", ".join(f"{c} {'+'.join(s)}" for c, s in sorted(by_cell.items())) or "empty"

    # ---- internals ----------------------------------------------------------------

    def _clean(self, readings):
        """Drop anything that is not a cell on this sheet, and renumber levels per cell.

        Levels come back from a language model, so they can be 1-based, repeated, or have a
        gap where it could not see the bottom of a stack. Only the *order* within a cell
        carries information, so sort by it and relabel 0, 1, 2.
        """
        by_cell = {}
        for i, r in enumerate(readings or []):
            cell = norm_cell(r.get("cell"))
            if cell is None:
                continue
            try:
                level = float(r.get("level") or 0)
            except (TypeError, ValueError):
                level = 0.0
            # `i` keeps the model's own order as the tie-break when it gives every block in a
            # cell the same level, which is the usual way it signals "I did not count".
            by_cell.setdefault(cell, []).append((level, i, norm_color(r.get("color"))))
        out = []
        self.clamped = []
        for cell, stack in by_cell.items():
            stack.sort()
            if len(stack) > MAX_STACK:
                # The arm cannot build higher than MAX_STACK and a cell is barely wider than
                # a cube, so a taller answer is the model over-reading shadow, not a tower.
                # Keep the bottom of the stack and say so, rather than rendering a level
                # nothing in Roblox could climb onto.
                self.clamped.append(f"{cell}:{len(stack)}")
                stack = stack[:MAX_STACK]
            for level, (_, _, color) in enumerate(stack):
                out.append({"cell": cell, "color": color, "level": level})
        return out

    def _identify(self, fresh):
        """Give each reading the id the same block had last time, where it can be recognised.

        Three passes, strictest first: the same colour in the same cell at the same level is
        certainly the same block; the same colour in the same cell is that block stacked or
        unstacked; the same colour anywhere is that block moved - and matching it is what
        keeps one platform gliding to its new cell, instead of one platform being destroyed
        while another appears somewhere else.

        A block the model could not name inherits whatever colour was last at that cell and
        level. That is the only memory in this module, and it earns its place: an overhead
        camera genuinely cannot see the colour of a block with another block on top of it.
        """
        spare = list(self._prev)

        for r in fresh:
            if r["color"] == UNKNOWN_COLOR:
                for old in spare:
                    if (old["cell"], old["level"]) == (r["cell"], r["level"]):
                        r["color"] = old["color"]
                        break

        taken = [None] * len(fresh)

        def claim(key):
            for i, r in enumerate(fresh):
                if taken[i] is not None:
                    continue
                for old in spare:
                    if key(old) == key(r):
                        taken[i] = old
                        spare.remove(old)
                        break

        claim(lambda e: (e["cell"], e["level"], e["color"]))
        claim(lambda e: (e["cell"], e["color"]))
        claim(lambda e: e["color"])

        out = []
        for r, old in zip(fresh, taken):
            if old is None:
                out.append({"id": self._next_id, **r})
                self._next_id += 1
            else:
                out.append({"id": old["id"], **r})
        return out

    def _to_json(self, e):
        """One wire block: resting, square to the grid, at its cell's centre.

        `held`, `yaw` and `visible` are kept at their resting values rather than dropped. The
        protocol is version 1 and `roblox/BlockSync.lua` reads all three, and keeping them
        means no Lua has to change for this. There is no longer any state in which `held` is
        true, and a block parked in a printed cell is square to that cell by construction, so
        there is no yaw left to measure.
        """
        x, y = cell_centre(e["cell"])
        return {
            "id": e["id"],
            "color": e["color"],
            "cell": e["cell"],
            "x": round(x, 1),
            "y": round(y, 1),
            "z": round(e["level"] * self.cube_mm, 1),
            "yaw": 0.0,
            "level": e["level"],
            "held": False,
            "visible": True,
            "age": 0.0,
        }


# ---- the model --------------------------------------------------------------------

API = "https://api.openai.com/v1/chat/completions"
DEFAULT_MODEL = "gpt-4o"        # override with OPENAI_MODEL; any vision model will do
TIMEOUT_S = 40
MAX_WIDTH = 1280                # the printed labels stay legible; a 1920 frame is wasted tokens

BILLING_URL = "https://platform.openai.com/settings/organization/billing"

# How tall a stack can get. The arm can place one cube on top of another and no higher, and a
# cell is only a little wider than a cube, so two is the real ceiling. Telling the model the
# ceiling is worth more than it looks: asked an open question an overhead view invites
# "maybe three?", and a phantom third level renders in Roblox as a tower nothing can climb.
MAX_STACK = 2

PROMPT = (
    "This is an overhead photo of foam cubes sitting on a printed grid. The grid has "
    f"{len(ROWS)} rows labelled {', '.join(ROWS)} and {len(COLS)} columns labelled "
    f"{', '.join(COLS)}, and every cell is printed with its own label like A1 or B3. Read the "
    "printed labels to decide which cell a cube is in; do not guess from position alone.\n\n"
    "Report every cell that has at least one cube in it. For each such cell, list the cubes "
    "from the bottom of the stack upwards.\n\n"
    "IMPORTANT - cubes can be stacked, and you must say when they are. A cell holds either "
    f"one cube or a stack of exactly {MAX_STACK} cubes, one sitting squarely on top of the "
    "other. Never report more than "
    f"{MAX_STACK} cubes in a cell. You are looking from directly above, so a stack of two "
    "does not look twice as wide - it looks TALLER, and these are the cues that give it "
    "away:\n"
    "  - a stack of two is noticeably closer to the camera, so it looks slightly larger than "
    "a single cube in a neighbouring cell, and it overhangs its cell's printed border more\n"
    "  - you can see more of its vertical side faces, as a thicker band of shaded colour "
    "around the top face\n"
    "  - it casts a longer shadow onto the sheet than a single cube does\n"
    "  - the horizontal seam between the two cubes is often visible on a side face\n"
    "  - a single cube looks flat against the paper, with almost no visible sides and a short "
    "shadow\n"
    "Compare each cube against the others in the photo rather than judging it alone: if one "
    "cube clearly stands higher than the rest, it is a stack of two. If a cell holds a stack "
    "of two but you cannot make out the colour of the lower cube - which is normal, because "
    "the cube on top hides most of it - give the lower cube's colour as \"unknown\" rather "
    "than leaving it out. Getting the count right matters more than getting that colour "
    "right.\n\n"
    f"Name colours from the ones this kit has: {', '.join(BLOCK_COLORS)}. Only if a cube "
    "clearly matches none of them, use another plain lowercase colour word. Judge each cube's "
    "main colour, ignoring glare and shadow.\n\n"
    "Ignore the robot arm, the gripper, anything the gripper is holding in the air, and "
    "anything that is not on the grid. A cube held in the gripper is not on the board.\n\n"
    'Reply with JSON only, shaped {"cells": [{"cell": "A1", "stack": ["red"]}, '
    '{"cell": "B2", "stack": ["unknown", "teal"]}]}, where "stack" runs bottom to top - so '
    'the A1 example is one red cube on the paper, and the B2 example is a teal cube sitting '
    'on top of another cube whose colour is hidden. Reply {"cells": []} if the grid is empty.'
)


class BoardUnavailable(RuntimeError):
    """A read did not happen. `kind` says why, so the UI can say something useful.

    The kind that matters to a human mid-demo is `no_credits`: the key is fine, the camera is
    fine, the code is fine, and the board has simply stopped updating until somebody tops the
    account up. That is indistinguishable from a crashed camera unless it is said out loud,
    so it travels all the way to the viewer and into Roblox. See `bridge/producers/board.py`.
    """

    KINDS = ("no_key", "no_credits", "rate_limit", "auth", "network", "reply", "frame")

    def __init__(self, message, kind="network"):
        super().__init__(message)
        self.kind = kind

    @property
    def fatal(self):
        """Will retrying unaided fix this? No, for a missing key or an empty account."""
        return self.kind in ("no_key", "no_credits", "auth")


def _api_key():
    key = os.environ.get("OPENAI_API_KEY")
    if key:
        return key.strip()
    env = Path(ROOT).parent / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            m = re.match(r"\s*OPENAI_API_KEY\s*=\s*['\"]?([^'\"\s]+)", line)
            if m:
                return m.group(1)
    return None


def available():
    return _api_key() is not None


def model_name():
    return os.environ.get("OPENAI_MODEL", DEFAULT_MODEL)


def encode(frame_bgr, max_width=MAX_WIDTH):
    """The frame as a JPEG data URL, scaled down to what the model needs."""
    import cv2
    img = frame_bgr
    if img.shape[1] > max_width:
        h = int(img.shape[0] * max_width / img.shape[1])
        img = cv2.resize(img, (max_width, h), interpolation=cv2.INTER_AREA)
    ok, jpg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 88])
    if not ok:
        raise BoardUnavailable("could not JPEG-encode the camera frame", "frame")
    return "data:image/jpeg;base64," + base64.b64encode(jpg).decode()


def parse(reply):
    """The model's JSON -> [{"cell", "color", "level"}]. Tolerant of either shape it may use.

    Accepts the documented {"cells": [{"cell", "stack": [...]}]} and also a flat list of
    {"cell", "color", "level"}, because that is the other obvious way to answer the question
    and there is no reason to throw a read away over it.
    """
    rows = reply.get("cells") if isinstance(reply, dict) else reply
    if isinstance(rows, dict):                  # {"A1": ["red"], ...}
        rows = [{"cell": k, "stack": v if isinstance(v, list) else [v]}
                for k, v in rows.items()]
    if not isinstance(rows, list):
        raise BoardUnavailable(f"reply has no cell list: {str(reply)[:200]}", "reply")
    out = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        cell, stack = row.get("cell"), row.get("stack")
        if isinstance(stack, list):
            for level, color in enumerate(stack):
                if isinstance(color, dict):     # [{"color": "red"}, ...]
                    color = color.get("color")
                out.append({"cell": cell, "color": color, "level": level})
        elif "color" in row or "colour" in row:
            out.append({"cell": cell, "color": row.get("color", row.get("colour")),
                        "level": row.get("level", 0)})
    return out


def _raise_for_http(r):
    """Turn an OpenAI error response into a BoardUnavailable with the right `kind`.

    The distinction that matters: a 429 is *either* "slow down" or "you are out of credits",
    and they are told apart only by `error.code` in the body. Reporting an empty account as a
    rate limit would have the demo waiting politely for a retry that can never succeed.
    """
    if r.ok:
        return
    try:
        body = r.json()
        err = (body.get("error") if isinstance(body, dict) else None) or {}
    except (ValueError, AttributeError):
        # A gateway or proxy in front of the API can answer with HTML, an empty body, or
        # JSON that is not an object at all. The status code still has to be classified.
        err = {}
    if not isinstance(err, dict):
        err = {}
    code = str(err.get("code") or err.get("type") or "")
    msg = err.get("message") or r.text[:200] or f"HTTP {r.status_code}"
    if code == "insufficient_quota" or "quota" in code or r.status_code == 402:
        raise BoardUnavailable(msg, "no_credits")
    if r.status_code == 429:
        raise BoardUnavailable(msg, "rate_limit")
    if r.status_code in (401, 403):
        raise BoardUnavailable(msg, "auth")
    raise BoardUnavailable(f"HTTP {r.status_code}: {msg}", "network")


def read_board(frame_bgr, key=None, model=None, timeout_s=TIMEOUT_S):
    """One model call. Returns [{"cell", "color", "level"}]; raises BoardUnavailable.

    `requests` is imported here rather than at module scope so that `bridge.board` stays
    importable - and `bridge.test_board` runnable - with nothing installed but OpenCV.
    """
    key = key or _api_key()
    if not key:
        raise BoardUnavailable(
            "no OPENAI_API_KEY (environment, or a .env at the repo root)", "no_key")
    try:
        import requests
    except ImportError:
        raise BoardUnavailable("the 'requests' package isn't installed", "network") from None

    model = model or model_name()
    body = {
        "model": model,
        "response_format": {"type": "json_object"},
        "temperature": 0,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": PROMPT},
            {"type": "image_url", "image_url": {"url": encode(frame_bgr), "detail": "high"}},
        ]}],
    }
    t = time.perf_counter()
    try:
        r = requests.post(API, headers={"Authorization": f"Bearer {key}"},
                          json=body, timeout=timeout_s)
    except requests.RequestException as e:
        raise BoardUnavailable(f"could not reach the API: {e}", "network") from None
    _raise_for_http(r)
    try:
        payload = r.json()
        reply = json.loads(payload["choices"][0]["message"]["content"])
    except (KeyError, IndexError, TypeError, ValueError) as e:
        raise BoardUnavailable(f"unreadable reply: {e}", "reply") from None
    out = parse(reply)
    usage = payload.get("usage") or {}
    read_board.last = {"model": model, "seconds": round(time.perf_counter() - t, 2),
                       "tokens": usage.get("total_tokens"), "raw": reply}
    return out
