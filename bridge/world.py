"""Blocks that keep their identity, and blocks that have a height.

`robot.perception.scene.build_scene` is accurate (4.4 mm) but it answers a different question
than a game needs. It reports, per frame, which colourful blobs are on the sheet, with two
consequences a Roblox BlockSync cannot live with:

  * **No stable identity.** Blocks are named by colour, and two blocks of one colour become
    `red_cube` and `red_cube_2` *in detection order*, which can swap between frames. One
    platform per block means one persistent id per block.
  * **No height.** Every block is mapped at mid-cube height on the paper. A stacked block and
    a block on the table read the same, and a block in the gripper is not reported at all,
    because the jaw covers it.

This module is the fix. It associates detections to tracks frame to frame, and uses the arm's
own forward kinematics (which the camera cannot argue with) for the two cases vision is blind
to: held blocks and stack level.

    tracker = BlockTracker()
    blocks = tracker.update(scene["objects"], arm, t)

Held. A track whose blob disappears close to the FK tip while the jaw is closed on something
is held, not gone, and its position becomes the tip's. That is what gives a crane lift its
height.

Released. When the jaw opens, the block is free again at the tip's xy. Its stack level is how
many other tracks already sit under that xy, so z = level * cube height. This is occlusion
memory: the camera never sees the lower block, the tracker remembers it is there.
"""

import json
import math
import os
import threading
from pathlib import Path

from robot.perception.config import SHEET_SPEC

CUBE_MM = 48.0

_DEBUG = bool(os.environ.get("WORLD_DEBUG"))

# Association. A block cannot teleport between frames, so a detection further than this from
# every track is a new block rather than a jump.
GATE_MM = 45.0                 # just under a cube edge: adjacent blocks stay distinguishable
COLOR_GATE_MM = 70.0           # a same-colour match is allowed to be looser
COLOR_PENALTY_MM = 15.0        # ...but at equal distance, prefer the same-colour match
CLAIM_PENALTY_MM = 35.0        # an unconfirmed grab loses a tie for the blob at its pick-up spot
MISS_HOLD_S = 0.5              # keep a vanished block's last pose this long before dimming it
DROP_AFTER_S = 3.0             # ...then forget it entirely, unless it is held
DROP_UNCOVERED_S = 0.8         # ...but much sooner if nothing could be hiding it
ARM_SHADOW_MM = 70.0           # a block this close to any arm joint may be under the arm
HELD_MAX_S = 25.0              # a hold this long was never released; treat it as stale
GRIP_SPAN_MIN = 6.0            # jaw range must be at least this wide to be worth trusting

# Grip. The follower reports the jaw as percent open: GRIPPER_OPEN=50 is open, and
# robot/skills.py treats a reading under MIN_GRASP=8 as closed on nothing.
# Measure yours with: python -m robot.scripts.tests.measure_grip
GRIP_CLOSED_PCT = 35.0         # narrower than this means closing or closed
GRIP_EMPTY_PCT = 8.0           # a reading this narrow means the jaw shut on air

# A grab used to require GRIP_EMPTY_PCT <= grip < GRIP_CLOSED_PCT, so a gripper that squeezed a
# cube tighter than 8% never registered a hold at all: the block was not marked held, aged out
# after DROP_AFTER_S and vanished from Roblox mid-carry - the lift's whole point. The real
# evidence of a grab is not the exact jaw width but that a *tracked block disappeared at the
# jaw tip*, which GRAB_RADIUS_MM already tests, so the lower bound is gone and only "not open"
# remains. GRIP_EMPTY_PCT is kept for reporting, not as a gate.
GRAB_RADIUS_MM = 55.0          # a block this close to the tip when it vanishes was picked up
HELD_COLOR = "grey"            # what a carried block reports; see _Track.to_json

# Smoothing. Platforms carry a player, so they must not shiver under their feet.
EMA_ALPHA = 0.45               # weight on the new reading
DEADBAND_MM = 0.5              # ignore movement smaller than this entirely
STACK_XY_MM = 35.0             # two blocks within this xy are the same stack (off-grid fallback)

# The board is a printed grid of cells a little larger than a cube, and the cubes are meant to
# sit in them. Snapping a resting block to its cell is not cosmetic rounding: it throws away
# jitter and the calibration's few mm of error at once, and it turns "are these two stacked?"
# from a distance test on noisy coordinates into an exact question - same cell or not. Two
# 48 mm cubes cannot share a 57 mm cell side by side, so same cell means stacked.
_GRID = json.loads(Path(SHEET_SPEC).read_text())["grid"]
GRID_ORIGIN_MM = tuple(float(v) for v in _GRID["origin_mm"])
CELL_MM = float(_GRID["cell_mm"])
GRID_ROWS, GRID_COLS = len(_GRID["rows"]), len(_GRID["cols"])

# A hold is believed only once the arm has carried it this far from where it was picked up.
# Until then the jaw might equally have closed on air beside the block.
CONFIRM_MOVE_MM = 40.0


def _cell_of(x, y):
    """(row, col) of the grid cell holding this point, or None if it is off the grid."""
    col = int(math.floor((x - GRID_ORIGIN_MM[0]) / CELL_MM))
    row = int(math.floor((y - GRID_ORIGIN_MM[1]) / CELL_MM))
    if 0 <= row < GRID_ROWS and 0 <= col < GRID_COLS:
        return row, col
    return None


def _cell_centre(cell):
    row, col = cell
    return (GRID_ORIGIN_MM[0] + (col + 0.5) * CELL_MM,
            GRID_ORIGIN_MM[1] + (row + 0.5) * CELL_MM)


def _same_stack(a, b):
    """Same cell if both are on the grid; otherwise fall back to a distance test, so blocks
    pushed off the printed area still behave sensibly instead of vanishing from the rules."""
    ca, cb = _cell_of(a.x, a.y), _cell_of(b.x, b.y)
    if ca is not None and cb is not None:
        return ca == cb
    return _dist(a.x, a.y, b.x, b.y) <= STACK_XY_MM


def _dist(ax, ay, bx, by):
    return math.hypot(ax - bx, ay - by)


def _color_of(name):
    """light_blue_cube_2 becomes "light blue". Names are colour + _cube + a dup index."""
    return name.split("_cube")[0].replace("_", " ")


class _Track:
    __slots__ = ("id", "color", "x", "y", "z", "yaw", "level", "held", "visible",
                 "last_seen", "settled_at", "score", "held_since", "pending", "grab_x", "grab_y", "tip0_x", "tip0_y", "tip0_z")

    def __init__(self, tid, color, x, y, yaw, t, score):
        self.id, self.color = tid, color
        self.x, self.y, self.z, self.yaw = x, y, 0.0, yaw
        self.level, self.held, self.visible = 0, False, True
        self.last_seen, self.score = t, score
        self.held_since = 0.0
        # A grab starts provisional: the jaw closing near a block looks identical to the jaw
        # closing on air beside it. `pending` means "claimed but not yet believed" - the block
        # does not move, go grey, or count as carried until the arm proves it by taking it
        # somewhere. grab_x/grab_y is where it was sitting when the jaw shut.
        self.pending = False
        self.grab_x, self.grab_y = 0.0, 0.0
        self.tip0_x, self.tip0_y, self.tip0_z = 0.0, 0.0, 0.0
        # When this block last came to rest where it now is. Decides stack order: the block
        # that arrived at a spot first is the one underneath.
        self.settled_at = t

    @property
    def carrying(self):
        """Held *and* confirmed. Everywhere that means "the arm has this block"."""
        return self.held and not self.pending

    def to_json(self, t):
        # A held block reports grey, not its real colour. Once it is in the jaw its position
        # comes from forward kinematics, which knows where the jaw is but nothing about what it
        # is holding - and the camera's view of a block clamped in a gripper is partly the
        # gripper. Grey is honest: "carried, colour not currently being measured". `self.color`
        # keeps the real value throughout, so association still matches on colour and the block
        # returns to its own colour the moment the jaw opens.
        x, y, yaw = self.x, self.y, self.yaw
        if not self.carrying:
            # Resting: snap to the cell it is in, and to the nearest quarter turn. A cube is
            # four-fold symmetric, so its yaw is only meaningful modulo 90 degrees - the
            # detector picks arbitrarily among four equally valid answers and the result
            # swung tens of degrees on a cube that never moved, which rendered as blocks
            # sitting askew on a square grid. A carried block keeps its measured pose: it is
            # between cells by definition, and the player may be standing on it.
            cell = _cell_of(x, y)
            if cell is not None:
                x, y = _cell_centre(cell)
            yaw = round(yaw / 90.0) * 90.0
        return {
            "id": self.id,
            "color": HELD_COLOR if self.carrying else self.color,
            "x": round(x, 1),
            "y": round(y, 1),
            "z": round(self.z, 1),
            "yaw": round(yaw, 1),
            "level": self.level,
            "held": self.carrying,
            "visible": self.visible,
            "age": round(t - self.last_seen, 2),
        }


class BlockTracker:
    def __init__(self, cube_mm=CUBE_MM):
        self.cube_mm = cube_mm
        self._tracks = []
        self._next_id = 1
        # The jaw's observed range, learned as it runs. See _grip_state.
        # A grab needs the jaw to have *closed*, not merely to be narrow. Set when the jaw is
        # seen open, cleared when a block is taken. See _resolve_unseen.
        self._armed = False
        self._arm_pts = []
        self._grip_lo = None
        self._grip_hi = None
        self._dbg_at = 0.0
        # update() runs on the vision thread and follow_tip() on the arm thread, so the track
        # list has two writers.
        self._lock = threading.RLock()

    def update(self, objects, arm=None, t=0.0):
        """objects: scene["objects"] from build_scene. arm: the dict a producer publishes.

        Returns the block list for the state frame. Safe to call with objects=[] (the camera
        lost the sheet): tracks keep their last pose and a held block keeps following the tip.
        """
        with self._lock:
            return self._update_locked(objects, arm, t)

    def _debug(self, tip, grip, closed, open_jaw, obs, t):
        """One line a second of everything the held/grab decision depends on.

        Turned on with WORLD_DEBUG=1. A block only becomes `held` when it vanishes from the
        camera while the jaw reads closed AND the kinematic tip is within GRAB_RADIUS_MM of
        where the camera last saw it - so when a carry is not tracking, the question is which
        of those three is false, and this prints all three rather than guessing.
        """
        if t - self._dbg_at < 1.0:
            return
        self._dbg_at = t
        where = f"tip=({tip['x']:6.1f},{tip['y']:6.1f},{tip['z']:5.1f})" if tip else "tip=NONE"
        span = "" if self._grip_lo is None else f" range[{self._grip_lo:.1f}..{self._grip_hi:.1f}]"
        print(f"[world] {where} grip={grip}{span} closed={closed} open={open_jaw} "
              f"blobs={len(obs)}")
        for tr in self._tracks:
            d = "   -  " if tip is None else f"{_dist(tr.x, tr.y, tip['x'], tip['y']):6.1f}"
            flag = ("HELD" if tr.carrying else "claim?") if tr.held else ("seen" if tr.visible else "lost")
            cell = _cell_of(tr.x, tr.y)
            where = "off-grid" if cell is None else f"r{cell[0]}c{cell[1]}"
            print(f"        id={tr.id} {tr.color:<6} {flag:<6} at ({tr.x:6.1f},{tr.y:6.1f}) "
                  f"{where} L{tr.level} dist_to_tip={d} mm")

    def _update_locked(self, objects, arm, t):
        tip, grip = self._arm_grip(arm)
        # The whole arm casts the shadow, not just the jaw - the forearm covers most of what
        # gets hidden. Fall back to the tip when a producer sends no stick figure.
        self._arm_pts = [(float(p["x"]), float(p["y"]))
                         for p in (arm or {}).get("points", []) if "x" in p]
        if not self._arm_pts and tip is not None:
            self._arm_pts = [(tip["x"], tip["y"])]

        obs = [{"color": _color_of(o["name"]),
                "x": float(o["center_mm"][0]),
                "y": float(o["center_mm"][1]),
                "yaw": float(o.get("yaw_deg", 0.0)),
                "score": float(o.get("score", 0.0))} for o in objects]

        closed, open_jaw = self._grip_state(grip)
        if open_jaw:
            self._armed = True
        pairs = self._associate(obs, open_jaw=open_jaw)
        matched_tracks = {track.id for track, _ in pairs}
        matched_obs = [o for _, o in pairs]

        for track, o in pairs:
            self._blend(track, o, t, open_jaw)

        for o in obs:
            if not any(o is used for used in matched_obs):
                self._tracks.append(
                    _Track(self._next_id, o["color"], o["x"], o["y"], o["yaw"], t, o["score"]))
                self._next_id += 1

        if _DEBUG:
            self._debug(tip, grip, closed, open_jaw, obs, t)
        self._resolve_unseen(matched_tracks, tip, closed, open_jaw, t)
        self._try_grab(tip, closed, t)
        self._settle_pending(tip, obs, t, {id(o): track.id for track, o in pairs})

        # A held block is rigid in the jaw, so its pose is the tip's - whether or not the
        # camera happened to see it this frame. Doing this in one place after association
        # keeps a *visible* held block moving with the arm; without it such a track stayed
        # frozen at the point of the grab, fell outside the match gate as the arm moved on,
        # and spawned a duplicate a few frames later.
        if tip is not None:
            for track in self._tracks:
                if track.carrying:
                    track.x, track.y, track.z = tip["x"], tip["y"], tip["z"]
        self._relevel()
        return [track.to_json(t) for track in self._tracks]

    def follow_tip(self, arm=None, t=0.0):
        """Advance only the held blocks from forward kinematics, and return the block list.

        The camera runs at VISION_HZ (10) while the arm runs at ARM_HZ (30). A carried block is
        rigid in the jaw, so where it is is a question for kinematics, not for the camera: its
        pose is simply the tip's. Driving it at the camera's rate made the Sky Arm glide while
        the block it was holding stuttered a third as often, with the camera's latency on top.

        This is deliberately *not* update(): update() with no detections treats every resting
        block as unseen and starts ageing it out, so calling it from the arm thread would
        quietly delete the blocks sitting on the table. Here nothing is associated, nothing
        ages, nothing is relevelled - held tracks move, everything else is left exactly as the
        last camera frame left it.
        """
        with self._lock:
            tip, _ = self._arm_grip(arm)
            if tip is not None:
                for track in self._tracks:
                    if track.carrying:
                        track.x, track.y, track.z = tip["x"], tip["y"], tip["z"]
                        track.last_seen = t
            return [track.to_json(t) for track in self._tracks]

    def tracks(self):
        with self._lock:
            return list(self._tracks)

    # ---- identity ---------------------------------------------------------------

    def _associate(self, obs, open_jaw=False):
        """Greedy nearest-neighbour, closest pair first. Greedy is enough here: blocks are at
        least a cube apart and move slowly, so the assignment is never ambiguous in practice,
        and a Hungarian solve would add a dependency for no measurable gain.

        Held blocks. While the jaw is closed a held block is under the gripper, so any blob
        near it is a *different* block and the held track must not be matched. The frame the
        jaw opens is the exception: the camera sees the block again that same frame, and if
        the held track is excluded then the reappearing blob spawns a duplicate track, which
        Roblox would render as a second platform for one real block. So on an open jaw a held
        track can re-attach, but only within the tight grab radius.
        """
        candidates = []
        # Tracks with a resting block on top of them. An overhead camera cannot see a buried
        # cube, so a blob at a stack is its top cube: with two cubes of one colour stacked, the
        # blob must go to the top track, or the top one goes unseen, counts as uncovered, and is
        # forgotten within DROP_UNCOVERED_S - the stack collapsing to its bottom cube. A held
        # cube (claimed or carried) covers nothing: it is on its way off the stack.
        covered = {track.id for track in self._tracks
                   if not track.held and any(other is not track and not other.held
                                             and other.settled_at > track.settled_at
                                             and _same_stack(track, other)
                                             for other in self._tracks)}
        for track in self._tracks:
            # While the jaw reads closed a held block is inside it, so a nearby blob is some
            # *other* block and must not be matched. The exception is a blob of the held
            # track's own colour within the grab radius: the camera plainly sees that block, so
            # it is not in the jaw - the frame the jaw lets go, or a grip reading that never
            # crosses the open threshold. Without the exception that blob matches nothing and
            # spawns a duplicate, which is how one cube became a pile.
            held_locked = track.carrying and not open_jaw
            for o in obs:
                same = o["color"] == track.color
                if held_locked and not same:
                    continue
                d = _dist(track.x, track.y, o["x"], o["y"])
                if not same and not track.carrying and d <= STACK_XY_MM:
                    # A blob of a different colour, right on top of a block that is sitting
                    # still, is the thing that was just stacked onto it - not this block having
                    # changed colour. Matching it here is what made a stack vanish: the teal
                    # cube was absorbed into the red cube's track, `_blend` overwrote the
                    # colour, and two real cubes became one. Skipping the pair lets a new track
                    # spawn, which is what `_relevel` needs to see a stack at all.
                    continue
                gate = GRAB_RADIUS_MM if track.carrying else (COLOR_GATE_MM if same else GATE_MM)
                if d <= gate:
                    cost = d + (0.0 if same else COLOR_PENALTY_MM)
                    if track.held and track.pending:
                        # Two cubes of one colour stacked, and the top one just claimed: after a
                        # real pick the camera sees the bottom cube at the same spot. That blob
                        # belongs to the bottom track, which is still there, not to the claim -
                        # otherwise _settle_pending reads it as the claimed cube left behind.
                        cost += CLAIM_PENALTY_MM
                    if track.id in covered:
                        cost += CLAIM_PENALTY_MM    # buried: the camera sees the cube above it
                    candidates.append((cost, track, o))
        candidates.sort(key=lambda c: c[0])

        used_tracks, used_obs, pairs = set(), [], []
        for _, track, o in candidates:
            if track.id in used_tracks or any(o is used for used in used_obs):
                continue
            used_tracks.add(track.id)
            used_obs.append(o)
            pairs.append((track, o))
        return pairs

    def _blend(self, track, o, t, open_jaw=True):
        """Smooth, with a deadband, so a platform does not vibrate under a standing player."""
        if track.carrying and not open_jaw:
            # Seen by the camera, but the jaw has not let go. Being visible does not mean a
            # block is free: a gripper does not always hide what it is carrying, and on this
            # rig the cube stays in view through most of a lift. Treating "visible" as
            # "released" dropped the block out of the held path about a second into every
            # carry, after which it crawled along at the camera's rate instead of the arm's.
            # The jaw decides when a block is let go; the camera only says where it is.
            # Position keeps coming from the tip, which is both faster and exactly right for
            # something rigidly clamped in the jaw.
            track.color = o["color"]
            track.score = o["score"]
            track.last_seen = t
            track.visible = True
            return
        moved = _dist(track.x, track.y, o["x"], o["y"])
        if moved > DEADBAND_MM:
            track.x += (o["x"] - track.x) * EMA_ALPHA
            track.y += (o["y"] - track.y) * EMA_ALPHA
        if moved > STACK_XY_MM or track.held:
            # Carried to a new spot (by hand, or by the jaw that just let go): it is the
            # newest arrival there, so it rests on top of whatever was already there.
            track.settled_at = t
        dyaw = (o["yaw"] - track.yaw + 45) % 90 - 45      # cube yaw wraps every 90 degrees
        track.yaw = (track.yaw + dyaw * EMA_ALPHA + 45) % 90 - 45
        track.color = o["color"]
        track.score = o["score"]
        track.last_seen = t
        track.visible = True
        # Reaching here with an open jaw is a release: the block is back on the table and the
        # camera has it again. But an unconfirmed claim must survive being seen - that is the
        # whole point of it. Clearing `held` here while `pending` stayed set left a track in a
        # state that could never resolve, so the claim hung forever and the block never moved.
        if not track.pending:
            track.held = False

    # ---- height -----------------------------------------------------------------

    def _arm_grip(self, arm):
        if not arm:
            return None, None
        return arm.get("tip"), (arm.get("joints") or {}).get("gripper")

    def _grip_state(self, grip):
        """(closed, open_jaw) from the jaw's own observed range, not a fixed percentage.

        Absolute thresholds are a trap here: what counts as "open" depends on the gripper and
        on its calibration, so a hardcoded GRIP_CLOSED_PCT that is wrong for this arm makes
        open_jaw permanently false. Nothing then ever releases, a held track can never
        re-attach to the block it put down, and every pick leaves another phantom behind.

        So learn the range instead. Once the jaw has been seen both open and shut the span is
        known, and open/closed are judged relative to it - correct for any gripper, with no
        measurement step. Until the span is wide enough to be meaningful, fall back to the
        constants.
        """
        if grip is None:
            return False, False
        self._grip_lo = grip if self._grip_lo is None else min(self._grip_lo, grip)
        self._grip_hi = grip if self._grip_hi is None else max(self._grip_hi, grip)
        span = self._grip_hi - self._grip_lo
        if span >= GRIP_SPAN_MIN:
            return (grip <= self._grip_lo + 0.4 * span,
                    grip >= self._grip_lo + 0.6 * span)
        return grip < GRIP_CLOSED_PCT, grip >= GRIP_CLOSED_PCT

    def _resolve_unseen(self, matched, tip, closed, open_jaw, t):
        """Decide what happened to every track the camera did not report this frame."""

        for track in list(self._tracks):
            if track.id in matched:
                continue

            if track.held:
                # A hold that was never released. If the grip thresholds do not match this
                # gripper, open_jaw can never go true, and without this the track would follow
                # the tip for the rest of the session while every later pick stranded another
                # one beside it - Roblox rendering a pile of phantom blocks at one xy for a
                # single real cube. Let it go and let the camera decide what is really there.
                if t - track.held_since > HELD_MAX_S:
                    track.held = False
                    track.visible = False
                    track.last_seen = t
                    track.settled_at = t
                    continue
                if open_jaw:
                    # Let go. It lands at the tip's xy, on top of whatever is already there.
                    track.held = False
                    track.pending = False
                    track.visible = False
                    track.last_seen = t
                    track.settled_at = t    # newest arrival at this xy, so it rests on top
                elif tip and track.carrying:
                    track.x, track.y, track.z = tip["x"], tip["y"], tip["z"]
                    track.last_seen = t
                continue

            age = t - track.last_seen
            if self._buried(track):
                # An overhead camera cannot see the bottom of a stack, so ageing it out would
                # delete the block the top one is resting on - the whole stack collapses to its
                # top cube, which is exactly what it looked like in Roblox. We know it is still
                # there: we watched something get placed on top of it. Report it as present,
                # because it is; it stops being buried the moment the block above is taken away
                # and the camera picks it up again.
                track.visible = True
                track.last_seen = t
                continue
            if age > MISS_HOLD_S:
                track.visible = False
            # Forget it fast when nothing could be covering it. Three seconds is the right
            # patience for a block the arm is sweeping over, but far too long for one picked
            # up and put down elsewhere by hand: the camera saw it arrive in its new cell
            # while the old track sat on the stack it had left, and for those seconds the
            # board showed the same cube twice.
            limit = DROP_UNCOVERED_S if self._in_the_open(track) else DROP_AFTER_S
            if age > limit:
                self._tracks.remove(track)

    def _settle_pending(self, tip, obs, t, owners=None):
        """Decide whether a claimed grab really picked the block up, and keep deciding.

        Jaw width plus proximity cannot tell "closed on the cube" from "closed on air two
        centimetres from it" - they are the same numbers - and asking the camera at the moment
        of the grab does not help, because the gripper is right there either way.

        Motion answers it. Once the arm has moved CONFIRM_MOVE_MM from where the claim was
        made, look back at that spot: a block of that colour still sitting there, and not where
        the jaw now is, was never picked up. Drop the claim and leave it alone. Otherwise the
        hold is real.

        The one case an overhead camera cannot resolve is a straight vertical lift: a cube in
        the jaw and a cube left on the table sit at the same xy, and height is the axis this
        camera does not measure. So the check keeps running after a hold is confirmed, and a
        carry that turns out to have been empty is cancelled the moment the arm moves sideways
        and the cube is still sitting where it was.

        This is what stopped phantom carries - a track towed across the board by an empty jaw
        while the real cube sat still, spawning a fresh track behind it every time.

        Only a blob this track could own counts as left behind: `owners` maps id(blob) to the
        track it was associated with this frame, and a blob another track owns is that other
        cube - the one underneath a same-colour stack, or a same-colour neighbour in the next
        cell (cell centres are 57 mm apart, inside GRAB_RADIUS_MM once a cube sits a few mm off
        centre). Without this, picking a cube next to or off a cube of its own colour cancelled
        every real carry. What stays ambiguous is a jaw closing on air over a same-colour stack:
        the camera sees one cube of that colour at that spot either way, so the claim stands.
        """
        if tip is None:
            return
        owners = owners or {}
        for track in self._tracks:
            if not track.held:
                continue
            # Measured from where the *jaw* was, not where the block was: at the moment of
            # a grab the two are already tens of mm apart (the jaw sits above and to one
            # side), which would otherwise read as a carry before the arm had moved at all.
            moved = math.sqrt(_dist(track.tip0_x, track.tip0_y, tip["x"], tip["y"]) ** 2
                              + (tip["z"] - track.tip0_z) ** 2)
            if moved < CONFIRM_MOVE_MM:
                continue            # not carried far enough to tell yet
            # Left behind: sitting where it was picked up, and not where the jaw is now.
            # Both tests are in xy, because that is all the camera measures.
            left_behind = any(
                o["color"] == track.color
                and owners.get(id(o), track.id) == track.id
                and _dist(o["x"], o["y"], track.grab_x, track.grab_y) <= GRAB_RADIUS_MM
                and _dist(o["x"], o["y"], tip["x"], tip["y"]) > GRAB_RADIUS_MM
                for o in obs)
            if left_behind:
                track.held = False
                track.pending = False
                track.visible = True
                track.last_seen = t
                self._armed = False
            elif track.pending:
                track.pending = False
                track.held_since = t

    def _in_the_open(self, track):
        """Is there anything that could be hiding this block from the camera?

        Only two things occlude an overhead view: another block on top of it, and the arm.
        If neither applies, a block the camera cannot see is not a block being missed - it is
        a block that is no longer there.
        """
        if self._buried(track):
            return False
        return all(_dist(track.x, track.y, px, py) > ARM_SHADOW_MM
                   for px, py in self._arm_pts)

    def _buried(self, track):
        """Is some other resting block sitting on top of this one?

        Arrival time decides which is on top, not the measured height: heights come from stack
        level rather than from a camera that cannot see height at all, and `_relevel` already
        uses the same rule. A block that arrived at this xy later is above.
        """
        if track.carrying:
            return False
        return any(other is not track and not other.carrying
                   and other.settled_at > track.settled_at
                   and _same_stack(track, other)
                   for other in self._tracks)

    def _try_grab(self, tip, closed, t):
        """Close the jaw within reach of a block and you are holding it.

        This used to live inside `_resolve_unseen`, which only ever looks at blocks the camera
        did *not* report - so a grab was detected only when the cube happened to vanish behind
        the gripper as it closed. That is not a property of picking something up, it is a
        property of the viewing angle: approach from where the overhead camera still sees the
        cube in the jaw and no grab ever fired, which is exactly what teleop does.

        So the test is geometric and mechanical, with the camera's opinion left out of it: the
        jaw has closed (`_armed`, see below), and a tracked block is within GRAB_RADIUS_MM of
        the tip. Whether that block is currently visible is irrelevant.

        `_armed` is why the trigger is "has just closed" rather than "is narrow". Measured on
        this arm, a real grip on a 48 mm cube reads 33% while a jaw merely parked half open
        reads 39%: no absolute width separates them, and the looser reading wins, gluing blocks
        to a jaw that is only passing overhead. A closing *transition* is unambiguous - the jaw
        must have been seen open since the last pick - and taking a block consumes it, so one
        open-close cycle picks up exactly one block.
        """
        if tip is None or not closed or not self._armed:
            return
        near = [tr for tr in self._tracks
                if not tr.held
                and t - tr.last_seen <= MISS_HOLD_S
                and _dist(tr.x, tr.y, tip["x"], tip["y"]) <= GRAB_RADIUS_MM]
        if not near:
            return
        track = min(near, key=lambda tr: _dist(tr.x, tr.y, tip["x"], tip["y"]))

        # The jaw holds exactly one block, so any older hold is stale by definition - release it
        # rather than letting two tracks ride the same tip.
        for other in self._tracks:
            if other is not track and other.held:
                other.held = False
                other.visible = False
                other.last_seen = t
                other.settled_at = t
        track.held = True
        track.held_since = t
        self._armed = False             # one open-close cycle, one block
        # Provisional. It stays exactly where it is until the arm carries it somewhere; see
        # _settle_pending for why proximity alone is not evidence of a grasp.
        track.pending = True
        track.grab_x, track.grab_y = track.x, track.y
        track.tip0_x, track.tip0_y, track.tip0_z = tip["x"], tip["y"], tip["z"]
        track.last_seen = t

    def _relevel(self):
        """Assign every resting block a stack level from how many blocks share its xy.

        Done for all tracks at once, after association, because a level depends on the other
        blocks' final positions. Within one stack the order is by how long each has been
        there: the block that arrived first is underneath.
        """
        resting = [track for track in self._tracks if not track.carrying]
        stacks = []
        for track in resting:
            for stack in stacks:
                if _same_stack(track, stack[0]):
                    stack.append(track)
                    break
            else:
                stacks.append([track])

        for stack in stacks:
            stack.sort(key=lambda tr: (tr.settled_at, tr.id))   # earliest arrival is underneath
            for level, track in enumerate(stack):
                track.level = level
                track.z = level * self.cube_mm
