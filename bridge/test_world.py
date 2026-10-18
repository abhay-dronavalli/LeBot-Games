"""Scripted scenarios for the block tracker, run without hardware or a camera.

    python -m bridge.test_world

Each scenario feeds the tracker hand-written detections plus a hand-written arm pose, which
is the only way to test held/stack inference: a real camera cannot be asked to hide a block
at a chosen moment.
"""

from bridge.world import BlockTracker, GRIP_CLOSED_PCT

OPEN, CLOSED = 50.0, 20.0


def obj(name, x, y, yaw=0.0):
    return {"name": name, "center_mm": [x, y], "yaw_deg": yaw, "score": 0.9}


def arm(x, y, z, grip):
    return {"tip": {"x": x, "y": y, "z": z}, "joints": {"gripper": grip}}


def ids(blocks):
    return {b["id"]: (b["x"], b["y"], b["z"], b["level"], b["held"], b["visible"]) for b in blocks}


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        print(f"        got  {got}")
        print(f"        want {want}")
    return ok


def scenario_identity_survives_a_swap():
    """Two same-colour blocks. build_scene may report them in either order with the names
    swapped; the tracker must keep each one's id pinned to its position."""
    print("identity: two red blocks, detection order flips")
    t = BlockTracker()
    t.update([obj("red_cube", 50, 50), obj("red_cube_2", 150, 200)], arm(0, 0, 200, OPEN), 0.0)
    # Same frame, reversed order and swapped dup-suffixes: exactly what the namer can do.
    blocks = t.update([obj("red_cube", 151, 201), obj("red_cube_2", 51, 51)], arm(0, 0, 200, OPEN), 0.1)
    by_id = ids(blocks)
    near_origin = [i for i, v in by_id.items() if v[0] < 100]
    far = [i for i, v in by_id.items() if v[0] >= 100]
    return (check("two tracks, not four", len(by_id), 2)
            and check("the block at 50,50 kept id 1", near_origin, [1])
            and check("the block at 150,200 kept id 2", far, [2]))


def scenario_pick_carry_release():
    """The crane lift: pick a block up, carry it 150 mm into the air, drop it on another."""
    print("crane lift: pick, carry, release onto another block")
    t = BlockTracker()
    ok = True
    # Two blocks on the table, 100 mm apart.
    t.update([obj("red_cube", 60, 60), obj("teal_cube", 160, 60)], arm(0, 0, 200, OPEN), 0.0)

    # Jaw arrives at the red block and closes. The jaw now covers it, so vision loses it.
    t.update([obj("red_cube", 60, 60), obj("teal_cube", 160, 60)], arm(60, 60, 14, OPEN), 0.5)
    blocks = t.update([obj("teal_cube", 160, 60)], arm(60, 60, 14, CLOSED), 0.6)
    # A grab is a claim, not a fact: the jaw closing on the cube and closing on air beside it
    # read identically. The block is not reported as held, and does not move, until the arm has
    # carried it far enough to prove the claim.
    ok &= check("red is claimed but not yet confirmed", ids(blocks)[1][4], False)
    # Still at its cell centre: a resting block is reported snapped to the printed grid, so
    # the raw 60,60 reads as A1's centre. A carried block is not snapped - it is between cells
    # by definition, and a player may be standing on it.
    ok &= check("and it has not moved", ids(blocks)[1][:3], (54.0, 50.8, 0.0))

    # Carried up and across. That is the proof, and from here only FK knows where it is.
    blocks = t.update([obj("teal_cube", 160, 60)], arm(110, 60, 150, CLOSED), 1.0)
    ok &= check("the carry confirms the hold", ids(blocks)[1][4], True)
    ok &= check("held block follows the tip to 150 mm up", ids(blocks)[1][:3], (110.0, 60.0, 150.0))

    # Positioned over the teal block and released.
    t.update([obj("teal_cube", 160, 60)], arm(160, 60, 60, CLOSED), 1.5)
    blocks = t.update([obj("teal_cube", 160, 60)], arm(160, 60, 60, OPEN), 1.6)
    by_id = ids(blocks)
    ok &= check("red is let go", by_id[1][4], False)
    ok &= check("red is now level 1, z=48", (by_id[1][3], by_id[1][2]), (1, 48.0))
    ok &= check("teal stays level 0, z=0", (by_id[2][3], by_id[2][2]), (0, 0.0))
    return ok


def scenario_blind_camera():
    """The sheet goes out of view mid-carry. Nothing may jump or disappear."""
    print("camera blind: sheet lost for a second while carrying")
    t = BlockTracker()
    ok = True
    t.update([obj("red_cube", 60, 60)], arm(0, 0, 200, OPEN), 0.0)
    t.update([obj("red_cube", 60, 60)], arm(60, 60, 14, OPEN), 0.3)
    t.update([], arm(60, 60, 14, CLOSED), 0.4)
    blocks = t.update([], arm(60, 60, 120, CLOSED), 0.9)       # no detections at all
    ok &= check("held block still tracked with no camera", ids(blocks)[1][:3], (60.0, 60.0, 120.0))
    blocks = t.update([], arm(60, 60, 120, CLOSED), 4.0)       # long blind spell
    ok &= check("a held block is never dropped from the list", len(blocks), 1)
    return ok


def scenario_vanished_block_is_forgotten():
    """A block taken off the table by hand must not haunt the game as a ghost platform."""
    print("removal: a block lifted off the sheet by hand")
    t = BlockTracker()
    ok = True
    t.update([obj("red_cube", 60, 60)], arm(300, 300, 200, OPEN), 0.0)
    blocks = t.update([], arm(300, 300, 200, OPEN), 0.2)       # jaw far away and open
    ok &= check("still shown briefly (one dropped frame is normal)", ids(blocks)[1][5], True)
    blocks = t.update([], arm(300, 300, 200, OPEN), 0.6)
    ok &= check("marked not visible after the hold window", ids(blocks)[1][5], False)
    # Nothing is on top of it and the arm is nowhere near, so there is no reason the camera
    # should have lost it: it is gone. Three seconds of patience belongs to a block the arm is
    # sweeping over, not to this.
    blocks = t.update([], arm(300, 300, 200, OPEN), 1.0)
    ok &= check("forgotten quickly when nothing could hide it", len(blocks), 0)

    # The same disappearance with the arm directly over it is a dropped frame, not a removal.
    t2 = BlockTracker()
    t2.update([obj("red_cube", 60, 60)], arm(60, 60, 120, OPEN), 0.0)
    blocks = t2.update([], arm(60, 60, 120, OPEN), 1.5)
    ok &= check("kept while the arm could be covering it", len(blocks), 1)
    blocks = t2.update([], arm(60, 60, 120, OPEN), 4.0)
    ok &= check("but not forever", len(blocks), 0)
    return ok


def scenario_deadband():
    """Camera noise must not move a platform under a standing player."""
    print("deadband: sub-millimetre jitter")
    t = BlockTracker()
    t.update([obj("red_cube", 100.0, 100.0)], arm(0, 0, 200, OPEN), 0.0)
    before = ids(t.update([obj("red_cube", 100.0, 100.0)], arm(0, 0, 200, OPEN), 0.1))[1][:2]
    after = ids(t.update([obj("red_cube", 100.3, 99.8)], arm(0, 0, 200, OPEN), 0.2))[1][:2]
    return check("0.3 mm of jitter moves nothing", before, after)


def scenario_grip_range_is_learned():
    """One real cube must stay one block, whatever the jaw's percentages happen to be.

    The release path used to hinge on a fixed GRIP_CLOSED_PCT. On a gripper whose open reading
    sits below that constant, open_jaw was never true, so a held track could neither release
    nor re-attach to the block it had just set down: every pick left another phantom behind and
    Roblox stacked a pile of blocks on one real cube. The jaw's range is now learned at
    runtime, so these all have to come back as a single track.
    """
    print("grip range: one cube stays one block on any gripper")
    ok = True
    for open_pct, closed_pct in ((50.0, 5.0), (30.0, 5.0), (22.0, 5.0),
                                 (15.0, 5.0), (12.0, 4.0), (60.0, 30.0)):
        t = BlockTracker()
        now, x, y, worst = 0.0, 100.0, 100.0, 1
        t.update([obj("red_cube", x, y)], arm(x, y, 200, open_pct), now)
        for cycle in range(4):
            tx, ty = (150.0, 120.0) if cycle % 2 == 0 else (100.0, 100.0)
            now += 0.1
            t.update([], arm(x, y, 200, closed_pct), now)
            for k in range(1, 11):          # the arm glides; it never teleports
                now += 0.1
                blocks = t.update([], arm(x + (tx - x) * k / 10.0,
                                          y + (ty - y) * k / 10.0, 200, closed_pct), now)
                worst = max(worst, len(blocks))
            for _ in range(8):              # jaw opens, the camera finds it again
                now += 0.1
                blocks = t.update([obj("red_cube", tx, ty)], arm(tx, ty, 200, open_pct), now)
                worst = max(worst, len(blocks))
            x, y = tx, ty
        ok &= check(f"open {open_pct:.0f}% / closed {closed_pct:.0f}% stays one block", worst, 1)
    return ok


def scenario_carry_stays_held_while_visible():
    """A gripper does not always hide what it is holding.

    The tracker used to read "the camera can see it" as "the jaw let go", so on a rig where the
    cube stays in view through the lift the block dropped out of the held path about a second
    into every carry - after which it crawled at the camera's rate instead of the arm's, and
    eventually fell outside the match gate and spawned a duplicate. The jaw decides release;
    the camera only says where things are.
    """
    print("carry: block stays visible in the jaw")
    t = BlockTracker()
    now = 0.0
    t.update([obj("red_cube", 100.0, 100.0)], arm(100, 100, 200, OPEN), now)
    now += 0.1
    blocks = t.update([], arm(100, 100, 40, CLOSED), now)        # one occluded frame
    ok = check("claimed, not yet confirmed", blocks[0]["held"], False)
    x = 100
    for k in range(1, 9):                                         # carried, and in view
        now += 0.1
        x = 100 + 12 * k
        blocks = t.update([obj("red_cube", float(x), 100.0)], arm(x, 100, 40, CLOSED), now)
    ok &= check("still held while visible", blocks[0]["held"], True)
    ok &= check("reports grey while carried", blocks[0]["color"], "grey")
    ok &= check("no duplicate spawned", len(blocks), 1)
    ok &= check("position follows the jaw, not the camera", round(blocks[0]["x"]), x)
    now += 0.1
    blocks = t.update([obj("red_cube", float(x), 100.0)], arm(x, 100, 40, OPEN), now)
    ok &= check("released when the jaw opens", blocks[0]["held"], False)
    ok &= check("own colour back once released", blocks[0]["color"], "red")
    return ok


def scenario_narrow_jaw_alone_is_not_a_grab():
    """Being narrow is not the same as having just closed.

    Measured on the real arm: a genuine grip on a 48 mm cube reads 33% while a jaw merely
    parked half open reads 39%. No absolute threshold separates those with margin, and the
    looser one wins, so an arm reaching across the sheet with a half-shut jaw collected blocks
    it never touched. A grab now requires the jaw to have been seen open since the last pick.
    """
    print("grab: a narrow jaw that never opened picks up nothing")
    t = BlockTracker()
    now = 0.0
    t.update([obj("red_cube", 100.0, 100.0)], arm(60, 60, 60, CLOSED), now)
    ok = True
    for k in range(1, 7):                     # drive the shut jaw onto the block and lift
        now += 0.1
        blocks = t.update([] if k > 2 else [obj("red_cube", 100.0, 100.0)],
                          arm(100, 100, 40 + 10 * k, CLOSED), now)
    ok &= check("not held: the jaw never opened", blocks[0]["held"], False)
    ok &= check("keeps its own colour", blocks[0]["color"], "red")

    now += 0.1                                 # now open the jaw: that arms the next grab
    t.update([obj("red_cube", 100.0, 100.0)], arm(100, 100, 40, OPEN), now)
    now += 0.1
    t.update([], arm(100, 100, 40, CLOSED), now)
    now += 0.1
    blocks = t.update([], arm(100, 100, 120, CLOSED), now)      # lifted: proves the claim
    ok &= check("held after a real open-then-close", blocks[0]["held"], True)

    now += 0.1                                 # a second block must not join the same jaw
    t.update([obj("blue_cube", 200.0, 100.0)], arm(200, 100, 40, CLOSED), now)
    now += 0.1
    blocks = t.update([], arm(200, 100, 40, CLOSED), now)
    held = [b for b in blocks if b["held"]]
    ok &= check("one open-close cycle holds one block", len(held), 1)
    return ok


def scenario_grab_without_occlusion():
    """Picking a block up must not depend on the camera losing sight of it.

    Grab detection used to live only on the "camera did not report this block" path, so it
    fired when the gripper happened to hide the cube as it closed. Under teleop the operator
    approaches from an angle where the overhead camera keeps seeing the cube in the jaw, and
    nothing was ever picked up. The cube here is visible on every single frame.
    """
    print("grab: block visible on every frame, never occluded")
    t = BlockTracker()
    now = 0.0
    t.update([obj("red_cube", 100.0, 100.0)], arm(100, 100, 60, OPEN), now)
    now += 0.1
    blocks = t.update([obj("red_cube", 100.0, 100.0)], arm(100, 100, 40, CLOSED), now)
    ok = check("claimed on a frame where it is plainly visible", blocks[0]["held"], False)
    x = 100
    for k in range(1, 6):
        now += 0.1
        x = 100 + 15 * k
        blocks = t.update([obj("red_cube", float(x), 100.0)], arm(x, 100, 90, CLOSED), now)
    ok &= check("confirmed once carried", blocks[0]["held"], True)
    ok &= check("still one block", len(blocks), 1)
    ok &= check("carried to the tip", round(blocks[0]["x"]), x)
    ok &= check("grey in the jaw", blocks[0]["color"], "grey")
    return ok


def scenario_stack_a_different_colour_on_top():
    """Put a teal cube on a red one. Both must survive, at two levels.

    Reported from the rig: "the red cube disappeared and all I see is the teal cube". Two
    separate rules were wrong. Association let a teal blob match the resting red track - the
    colour gate allowed a mismatch at a cost - so `_blend` repainted red as teal and two real
    cubes became one track. And an overhead camera cannot see the bottom of a stack, so even
    once the tracks were separate the lower one aged out after DROP_AFTER_S and took the
    stack's foundation with it.
    """
    print("stack: teal placed on top of red")
    t = BlockTracker()
    now = 0.0
    # Red is resting, seen for a while, settled.
    for _ in range(6):
        now += 0.1
        t.update([obj("red_cube", 150.0, 120.0)], arm(60, 60, 120, OPEN), now)

    # Teal is picked up elsewhere and carried over the red one.
    now += 0.1
    t.update([obj("red_cube", 150.0, 120.0), obj("teal_cube", 60.0, 60.0)],
             arm(60, 60, 40, OPEN), now)
    now += 0.1
    t.update([obj("red_cube", 150.0, 120.0)], arm(60, 60, 40, CLOSED), now)   # grabbed
    for k in range(1, 5):
        now += 0.1
        t.update([obj("red_cube", 150.0, 120.0)],
                 arm(60 + 23 * k, 60 + 15 * k, 120, CLOSED), now)

    # Released directly above the red cube. From here the camera only ever sees teal: it is
    # on top, and the red cube is underneath it.
    now += 0.1
    blocks = t.update([obj("teal_cube", 152.0, 121.0)], arm(152, 121, 60, OPEN), now)
    for _ in range(45):                      # well past DROP_AFTER_S
        now += 0.1
        blocks = t.update([obj("teal_cube", 152.0, 121.0)], arm(152, 121, 60, OPEN), now)

    ok = check("both cubes still tracked", len(blocks), 2)
    by_color = {b["color"]: b for b in blocks}
    ok &= check("colours kept apart", sorted(by_color), ["red", "teal"])
    if sorted(by_color) == ["red", "teal"]:
        ok &= check("red is underneath", by_color["red"]["level"], 0)
        ok &= check("teal is on top", by_color["teal"]["level"], 1)
        ok &= check("buried red still reported present", by_color["red"]["visible"], True)

    # Take the teal cube away by hand: the red one is visible again and drops back to level 0.
    # Give it longer than DROP_AFTER_S, since the teal track has to age out on its own - it is
    # no longer buried by anything, so nothing exempts it.
    for _ in range(40):
        now += 0.1
        blocks = t.update([obj("red_cube", 150.0, 120.0)], arm(60, 60, 120, OPEN), now)
    ok &= check("red back on its own", [b["color"] for b in blocks], ["red"])
    ok &= check("red back to level 0", blocks[0]["level"], 0)
    return ok


def scenario_empty_jaw_carries_nothing():
    """The jaw closes beside a cube, not on it, and the arm flies off. Nothing goes with it.

    Straight from the rig log: a track marked HELD was towed to (188,96) while the camera
    plainly saw its teal cube sitting still at (112,126) - and because the held track had been
    dragged away from the real blob, the blob no longer matched anything and spawned a fresh
    track behind it. Two cubes, nine track ids. Proximity plus a shut jaw is not a grasp.
    """
    print("grab: jaw shuts beside the cube, then leaves without it")
    t = BlockTracker()
    now = 0.0
    t.update([obj("red_cube", 150.0, 120.0)], arm(60, 60, 120, OPEN), now)
    now += 0.1
    t.update([obj("red_cube", 150.0, 120.0)], arm(145, 115, 40, OPEN), now)   # alongside it
    now += 0.1
    blocks = t.update([obj("red_cube", 150.0, 120.0)], arm(145, 115, 40, CLOSED), now)
    ok = check("claimed, not yet believed", blocks[0]["held"], False)

    # The arm leaves. The cube stays exactly where it was, in full view the whole time.
    for k in range(1, 8):
        now += 0.1
        blocks = t.update([obj("red_cube", 150.0, 120.0)],
                          arm(145 - 18 * k, 115 - 12 * k, 120, CLOSED), now)
    ok &= check("the claim was dropped", blocks[0]["held"], False)
    ok &= check("no phantom second track", len(blocks), 1)
    ok &= check("cube still in its own cell", (blocks[0]["x"], blocks[0]["y"]), (168.3, 107.9))
    ok &= check("and still its own colour", blocks[0]["color"], "red")
    return ok


def scenario_resting_blocks_snap_to_the_grid():
    """Jitter and a spinning yaw must not reach the game.

    The detector re-measures a resting cube every frame, so its position wanders by a few mm
    and its yaw swings freely - a cube is four-fold symmetric, so the detector is choosing
    arbitrarily between four equally correct answers. On the rig that rendered as cubes sitting
    crooked on a square grid and shivering in place. A resting block belongs in a cell.
    """
    print("snap: a jittering, spinning detection rests in one cell")
    t = BlockTracker()
    now = 0.0
    seen = set()
    for dx, dy, yaw in ((0.0, 0.0, 2.0), (3.1, -2.4, -27.1), (-2.8, 3.3, 41.0),
                        (1.9, 2.0, -16.8), (-3.4, -1.1, 8.1)):
        now += 0.1
        blocks = t.update([obj("red_cube", 150.0 + dx, 120.0 + dy, yaw=yaw)],
                          arm(60, 60, 150, OPEN), now)
        seen.add((blocks[0]["x"], blocks[0]["y"], blocks[0]["yaw"]))
    ok = check("one pose, however much it jitters", len(seen), 1)
    ok &= check("parked at the cell centre", (blocks[0]["x"], blocks[0]["y"]), (168.3, 107.9))
    ok &= check("square to the grid", blocks[0]["yaw"] % 90, 0.0)
    return ok


def main():
    results = [
        scenario_identity_survives_a_swap(),
        scenario_pick_carry_release(),
        scenario_blind_camera(),
        scenario_vanished_block_is_forgotten(),
        scenario_deadband(),
        scenario_grip_range_is_learned(),
        scenario_carry_stays_held_while_visible(),
        scenario_narrow_jaw_alone_is_not_a_grab(),
        scenario_grab_without_occlusion(),
        scenario_stack_a_different_colour_on_top(),
        scenario_empty_jaw_carries_nothing(),
        scenario_resting_blocks_snap_to_the_grid(),
    ]
    print(f"\n{sum(1 for r in results if r)}/{len(results)} scenarios passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
