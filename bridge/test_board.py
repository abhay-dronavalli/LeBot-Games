"""Scenarios for the board, run without a camera, an API key or hardware.

    python -m bridge.test_board

Replaces `test_world.py`'s twelve tracker scenarios. Most of those tested behaviour that no
longer exists - grip-range learning, phantom carries, occlusion memory, deadbanded jitter -
because nothing is tracked between reads any more. What is left to get wrong is narrower and
all of it is here: reading a model's loosely-shaped JSON, keeping ids stable across reads so
one block stays one Roblox platform, and firing the read on the right edge of the gripper.
"""

import time

from bridge import board as board_mod
from bridge.board import Board, ReleaseTrigger

OPEN, CLOSED = 50.0, 20.0


def ids(blocks):
    return {b["id"]: (b["cell"], b["color"], b["level"]) for b in blocks}


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        print(f"        got  {got}")
        print(f"        want {want}")
    return ok


def scenario_cells_become_sheet_mm():
    """A cell label has to land on the grid the arm and the viewer already agree on."""
    print("geometry: cell labels -> sheet mm")
    b = Board()
    blocks = b.apply([{"cell": "A1", "color": "red", "level": 0}])
    want = board_mod.cell_centre("A1")
    ok = check("A1 maps to its centre", (blocks[0]["x"], blocks[0]["y"]),
               (round(want[0], 1), round(want[1], 1)))
    # Round trip: the mock converts the other way, and the two must agree or the fake board
    # lands in a different cell than the one the fake arm reached for.
    ok &= check("mm -> cell -> mm is stable", board_mod.cell_of(*want), "A1")
    ok &= check("every cell on the sheet round-trips",
                [c for c in board_mod.cells()
                 if board_mod.cell_of(*board_mod.cell_centre(c)) != c], [])
    ok &= check("off the grid is off the grid", board_mod.cell_of(-50.0, -50.0), None)
    ok &= check("a label that is not a cell is rejected", board_mod.cell_centre("Z9"), None)
    return ok


def scenario_stacks_get_levels():
    """A stack of two is the point of the stacking prompt: both cubes, two levels."""
    print("stacking: a cell with two cubes")
    b = Board()
    blocks = b.apply(board_mod.parse(
        {"cells": [{"cell": "C4", "stack": ["red", "teal"]}]}))
    by_level = {x["level"]: x["color"] for x in blocks}
    ok = check("both cubes are reported", len(blocks), 2)
    ok &= check("red is underneath, teal on top", by_level, {0: "red", 1: "teal"})
    heights = {x["level"]: x["z"] for x in blocks}
    ok &= check("height comes from the level", heights, {0: 0.0, 1: round(b.cube_mm, 1)})
    ok &= check("both sit in the same cell", {x["cell"] for x in blocks}, {"C4"})
    return ok


def scenario_stack_taller_than_the_arm_can_build():
    """The arm stacks one cube on another and no higher, so three is a misread.

    An overhead view invites over-reading a long shadow as another cube, and a phantom third
    level renders in Roblox as a tower nothing can climb onto. The prompt states the ceiling;
    this is the backstop for when the model ignores it.
    """
    print(f"stacking: a reported stack of 3 is clamped to {board_mod.MAX_STACK}")
    b = Board()
    blocks = b.apply(board_mod.parse(
        {"cells": [{"cell": "B2", "stack": ["red", "teal", "yellow"]}]}))
    ok = check("clamped to the real ceiling", len(blocks), board_mod.MAX_STACK)
    ok &= check("the bottom of the stack is what is kept",
                sorted(x["color"] for x in blocks), ["red", "teal"])
    ok &= check("and it is reported, not swallowed", b.clamped, ["B2:3"])
    return ok


def scenario_unknown_colour_is_remembered():
    """An overhead camera cannot see the colour of a buried cube, so the model says so.

    This is the only memory the board keeps, and it is what stops a stacked cube turning grey
    the moment something is placed on it.
    """
    print("memory: a buried cube keeps the colour it had before it was buried")
    b = Board()
    b.apply([{"cell": "C4", "color": "teal", "level": 0}])
    blocks = b.apply(board_mod.parse(
        {"cells": [{"cell": "C4", "stack": ["unknown", "red"]}]}))
    by_level = {x["level"]: x["color"] for x in blocks}
    ok = check("the buried cube is still teal", by_level, {0: "teal", 1: "red"})
    # With nothing remembered there is nothing to recover, and grey is the honest answer.
    b2 = Board()
    blocks = b2.apply(board_mod.parse({"cells": [{"cell": "A1", "stack": ["unknown"]}]}))
    ok &= check("but an unknown with no history stays grey", blocks[0]["color"], "grey")
    return ok


def scenario_ids_survive_a_move():
    """One real block is one Roblox platform, across reads.

    BlockSync destroys a part whose id stops being reported and builds one for an id it has
    not seen. If a block moving from A1 to B2 came back with a new id, the platform the player
    is standing next to would be deleted and rebuilt somewhere else.
    """
    print("identity: a block keeps its id as it moves and stacks")
    b = Board()
    first = b.apply([{"cell": "A1", "color": "red", "level": 0},
                     {"cell": "C4", "color": "teal", "level": 0}])
    red = next(x["id"] for x in first if x["color"] == "red")
    teal = next(x["id"] for x in first if x["color"] == "teal")

    moved = b.apply([{"cell": "B2", "color": "red", "level": 0},
                     {"cell": "C4", "color": "teal", "level": 0}])
    ok = check("red kept its id after moving cell",
               next(x["id"] for x in moved if x["color"] == "red"), red)
    ok &= check("teal kept its id by standing still",
                next(x["id"] for x in moved if x["color"] == "teal"), teal)

    stacked = b.apply(board_mod.parse({"cells": [{"cell": "C4", "stack": ["teal", "red"]}]}))
    ok &= check("ids survive being stacked", ids(stacked),
                {teal: ("C4", "teal", 0), red: ("C4", "red", 1)})
    ok &= check("no third id was minted", len(stacked), 2)

    # Taken off the sheet by hand: the block is simply gone, and Roblox removes its platform.
    gone = b.apply([{"cell": "C4", "color": "teal", "level": 0}])
    ok &= check("a removed block disappears", list(ids(gone)), [teal])
    # ...and coming back is a new block, because nothing claims otherwise.
    back = b.apply([{"cell": "C4", "color": "teal", "level": 0},
                    {"cell": "A1", "color": "red", "level": 0}])
    ok &= check("it comes back as a fresh id", len(ids(back)), 2)
    return ok


def scenario_two_of_one_colour():
    """Two red cubes must stay two platforms, whichever order the model lists them in."""
    print("identity: two cubes of the same colour")
    b = Board()
    first = b.apply([{"cell": "A1", "color": "red", "level": 0},
                     {"cell": "C4", "color": "red", "level": 0}])
    ok = check("two separate ids", len(ids(first)), 2)
    at = {x["cell"]: x["id"] for x in first}
    # Same board, listed the other way round - a model has no reason to be consistent.
    again = b.apply([{"cell": "C4", "color": "red", "level": 0},
                     {"cell": "A1", "color": "red", "level": 0}])
    ok &= check("order does not change who is who",
                {x["cell"]: x["id"] for x in again}, at)
    ok &= check("still two, not four", len(again), 2)
    return ok


def scenario_reply_shapes():
    """The reader has to survive a model answering in a reasonable but undocumented shape."""
    print("parsing: the shapes a model actually replies with")
    want = [{"cell": "A1", "color": "red", "level": 0}]
    ok = check("the documented shape",
               board_mod.parse({"cells": [{"cell": "A1", "stack": ["red"]}]}), want)
    ok &= check("a flat list of cells",
                board_mod.parse([{"cell": "A1", "color": "red", "level": 0}]), want)
    ok &= check("a cell -> stack map",
                board_mod.parse({"cells": {"A1": ["red"]}}), want)
    ok &= check("objects inside the stack",
                board_mod.parse({"cells": [{"cell": "A1", "stack": [{"color": "red"}]}]}), want)
    ok &= check("British spelling",
                board_mod.parse([{"cell": "A1", "colour": "red"}]), want)
    ok &= check("an empty board", board_mod.parse({"cells": []}), [])

    b = Board()
    # Junk cells are dropped rather than failing the read, and a model that numbers levels
    # from 1, or gives every cube in a stack the same level, still gets a sane stack out.
    blocks = b.apply([{"cell": "Q7", "color": "red", "level": 0},
                      {"cell": "", "color": "red", "level": 0},
                      {"cell": "b2", "color": "teal", "level": 1},
                      {"cell": "B 2", "color": "red", "level": 1}])
    ok &= check("cells that do not exist are dropped", len(blocks), 2)
    ok &= check("levels are renumbered from 0",
                sorted(x["level"] for x in blocks), [0, 1])
    ok &= check("a lowercase label is the same cell", {x["cell"] for x in blocks}, {"B2"})
    return ok


def scenario_release_fires_the_read():
    """The trigger: two seconds after the jaw opens, and not on a clock."""
    print("trigger: a read follows the gripper opening")
    tr = ReleaseTrigger(delay_s=2.0)
    t = 100.0
    ok = check("nothing is owed before anything happens", tr.due(t), False)

    # Give the trigger the jaw's range to learn: shut, then open.
    for _ in range(3):
        t += 0.1
        tr.feed(CLOSED, t)
    ok &= check("a closed jaw asks for nothing", tr.due(t), False)

    t += 0.1
    tr.feed(OPEN, t)                                  # the release
    opened = t
    ok &= check("not read instantly - the arm is still in the way", tr.due(t), False)
    t = opened + 1.9
    ok &= check("still waiting at 1.9 s", tr.due(t), False)
    t = opened + 2.0
    ok &= check("read at 2.0 s", tr.due(t), True)
    ok &= check("and only once", tr.due(t + 5.0), False)

    # Holding the jaw open does not keep asking: it is the edge that matters, not the level.
    for _ in range(50):
        t += 0.1
        tr.feed(OPEN, t)
    ok &= check("an open jaw does not re-trigger", tr.due(t + 10.0), False)

    # Close and open again: that is another release, so another read.
    t += 0.1
    tr.feed(CLOSED, t)
    t += 0.1
    tr.feed(OPEN, t)
    ok &= check("the next release asks again", tr.due(t + 2.0), True)
    ok &= check("two releases, two reads", tr.count, 2)
    return ok


def scenario_trigger_learns_any_gripper():
    """Absolute grip thresholds are a trap; the range is learned.

    `world.py` was burned by this: a gripper whose open reading sat under a hardcoded constant
    meant "open" was never true. Here that would mean the board is read once at startup and
    never again, which looks exactly like a broken camera.
    """
    print("trigger: open and closed are learned, not assumed")
    ok = True
    for open_pct, closed_pct in ((50.0, 5.0), (30.0, 5.0), (22.0, 5.0),
                                 (15.0, 4.0), (12.0, 3.0), (60.0, 30.0)):
        tr = ReleaseTrigger(delay_s=2.0)
        t, fired = 0.0, 0
        for _ in range(3):                      # two full open-close-open cycles
            for grip in (closed_pct, open_pct):
                for _ in range(5):
                    t += 0.1
                    tr.feed(grip, t)
            if tr.due(t + 2.0):
                fired += 1
        ok &= check(f"open {open_pct:.0f}% / closed {closed_pct:.0f}% triggers reads",
                    fired >= 2, True)
    return ok


def scenario_board_is_republished_between_reads():
    """Between reads the board does not change - including while a block is being carried.

    This is the simplification the whole rewrite rests on. There is no held state: a cube in
    the jaw is still reported in the cell it was last read in, so a platform never vanishes
    from under a player who is standing on it, and it moves when the next read says so.
    """
    print("carry: the board holds still while a block is in the air")
    b = Board()
    b.apply([{"cell": "A1", "color": "red", "level": 0},
             {"cell": "C4", "color": "teal", "level": 0}])
    before = ids(b.blocks())
    ok = check("the board is readable without re-reading", before, ids(b.blocks()))
    ok &= check("nothing is ever held", [x["held"] for x in b.blocks()], [False, False])
    ok &= check("and nothing is ever stale", [x["visible"] for x in b.blocks()], [True, True])
    # The model's answer mid-carry leaves the carried cube out, because it is in the air.
    # The board does not change until the arm puts it down, so A1 keeps its platform.
    ok &= check("a block in the air is still shown where it was", before[1][0], "A1")
    after = b.apply([{"cell": "C4", "color": "teal", "level": 0},
                     {"cell": "C4", "color": "red", "level": 1}])
    ok &= check("and moves when the next read says so",
                {x["id"]: x["cell"] for x in after}, {1: "C4", 2: "C4"})
    return ok


def scenario_empty_board():
    """A bare sheet is a real answer, not a failed read."""
    print("empty: a sheet with nothing on it")
    b = Board()
    b.apply([{"cell": "A1", "color": "red", "level": 0}])
    blocks = b.apply([])
    ok = check("every platform goes away", blocks, [])
    ok &= check("summary says so", b.summary(), "empty")
    ok &= check("the read still counted", b.reads, 2)
    return ok


def scenario_quota_is_told_apart_from_a_rate_limit():
    """Both are HTTP 429, and only one of them a human can fix.

    An empty account reported as a rate limit has the demo waiting politely for a retry that
    can never succeed, with no idea why the board stopped moving.
    """
    print("errors: out of credits vs. slow down")

    class FakeResponse:
        def __init__(self, status, payload, ok=False):
            self.status_code, self._payload, self.ok = status, payload, ok
            self.text = str(payload)

        def json(self):
            return self._payload

    def kind_of(resp):
        try:
            board_mod._raise_for_http(resp)
        except board_mod.BoardUnavailable as e:
            return e.kind, e.fatal
        return None, None

    quota = FakeResponse(429, {"error": {"code": "insufficient_quota",
                                         "message": "You exceeded your current quota"}})
    limit = FakeResponse(429, {"error": {"code": "rate_limit_exceeded",
                                         "message": "Rate limit reached"}})
    bad_key = FakeResponse(401, {"error": {"code": "invalid_api_key", "message": "no"}})
    ok = check("an empty account is no_credits", kind_of(quota), ("no_credits", True))
    ok &= check("a rate limit is not, and clears on its own",
                kind_of(limit), ("rate_limit", False))
    ok &= check("a bad key is its own thing", kind_of(bad_key), ("auth", True))
    ok &= check("a good response raises nothing",
                kind_of(FakeResponse(200, {}, ok=True)), (None, None))
    ok &= check("a 402 is out of credits too",
                kind_of(FakeResponse(402, {}))[0], "no_credits")
    ok &= check("an error body that is not JSON still classifies",
                kind_of(FakeResponse(500, None))[0], "network")
    return ok


def scenario_mock_board_matches_the_model():
    """The mock has to answer the question the model answers, or it tests nothing.

    It is the only thing that exercises this path without a key and a camera, so its readings
    have to be the same shape and carry the same two blind spots: a cube in the jaw is absent,
    and a buried cube's colour is unknown.
    """
    print("mock: the fake board reads like a real one")
    from bridge.producers.mock import MockRig
    rig = MockRig()
    reading = rig.board_reading()
    ok = check("both cubes are on the board", len(reading), 2)
    ok &= check("every entry names a real cell",
                [r for r in reading if board_mod.norm_cell(r["cell"]) is None], [])
    ok &= check("and the Board accepts it", len(Board().apply(reading)), 2)

    # Pick one up: it leaves the board, and the Board keeps showing it where it was.
    b = Board()
    b.apply(rig.board_reading())
    was = {x["id"]: x["cell"] for x in b.blocks()}
    rig.grabbed = rig.order[0]
    ok &= check("a cube in the jaw is not on the board", len(rig.board_reading()), 1)
    ok &= check("but it is still on the last board read", b.blocks()[0]["cell"], was[1])

    # Stack them and the lower one's colour becomes unknown, as it does from overhead.
    rig.grabbed = None
    rig.blocks[rig.order[1]] = list(rig.blocks[rig.order[0]])
    stacked = sorted(rig.board_reading(), key=lambda r: r["level"])
    ok &= check("stacked, the lower cube's colour is unknown",
                stacked[0]["color"], board_mod.UNKNOWN_COLOR)
    ok &= check("and the Board recovers it from memory",
                b.apply(stacked)[0]["color"] != board_mod.UNKNOWN_COLOR, True)
    return ok


def main():
    results = [
        scenario_cells_become_sheet_mm(),
        scenario_stacks_get_levels(),
        scenario_stack_taller_than_the_arm_can_build(),
        scenario_unknown_colour_is_remembered(),
        scenario_ids_survive_a_move(),
        scenario_two_of_one_colour(),
        scenario_reply_shapes(),
        scenario_release_fires_the_read(),
        scenario_trigger_learns_any_gripper(),
        scenario_board_is_republished_between_reads(),
        scenario_empty_board(),
        scenario_quota_is_told_apart_from_a_rate_limit(),
        scenario_mock_board_matches_the_model(),
    ]
    print(f"\n{sum(1 for r in results if r)}/{len(results)} scenarios passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
