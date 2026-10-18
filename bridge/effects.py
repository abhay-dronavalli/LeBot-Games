"""Roblox -> real arm. Game events become modifiers on the joint command.

Each effect is a function of (action, age, intensity) -> action, where `action` is the
leader's command in follower degrees: {"shoulder_pan.pos": 12.1, ...}. Effects stack, expire
on their own, and are applied in a fixed order so two effects never fight over ordering.

Safety. The caps below are *hard* and not configurable from the wire: a game script sending
intensity=50 must not be able to cook a servo. Everything is clamped again downstream by
`max_relative_target` on the follower and by the calibrated joint ranges, so this is the
first of three limits, not the only one.

    stack = EffectStack()
    stack.add("earthquake", intensity=0.7, duration=4)
    action = stack.apply(leader.get_action(), time.perf_counter())
"""

import math
import random
import time

# name -> (max intensity, max duration seconds). A request past these is clamped, not refused.
LIMITS = {
    "earthquake":     (1.0, 5.0),
    "fog":            (1.0, 10.0),
    "mirror":         (1.0, 15.0),
    "molasses":       (1.0, 10.0),
    "butterfingers":  (1.0, 8.0),
    "freeze":         (1.0, 3.0),
}

EARTHQUAKE_MAX_DEG = 3.0      # peak joint wobble. The servos heat up; do not raise this.
EARTHQUAKE_HZ = 7.0
EARTHQUAKE_JOINTS = ["shoulder_pan", "wrist_flex", "wrist_roll"]  # never the lift: it drops the load
FOG_MAX_LAG_S = 0.8
MOLASSES_MAX_ALPHA = 0.92     # low-pass weight on the previous command; 1.0 would freeze it
BUTTERFINGERS_OPEN_PCT = 18.0  # the gripper cannot close past this, so a held block may slip

ORDER = ["mirror", "molasses", "fog", "butterfingers", "earthquake", "freeze"]


class EffectStack:
    LIMITS = LIMITS          # so the server can validate a name without importing the module

    def __init__(self, now=None):
        self._now = now or time.perf_counter
        self._active = {}        # name -> {"start", "duration", "intensity"}
        self._history = []       # [(t, action)] for fog's lag
        self._smoothed = None    # molasses state
        self._frozen = None      # the pose freeze holds
        self._rng = random.Random(0xB10C)

    # ---- control ----------------------------------------------------------------

    def add(self, name, intensity=1.0, duration=3.0):
        """Start or restart an effect. Unknown names are ignored (a typo in a game script
        must not kill the robot loop). Returns the clamped (intensity, duration)."""
        if name not in LIMITS:
            return None
        max_i, max_d = LIMITS[name]
        intensity = max(0.0, min(float(intensity), max_i))
        duration = max(0.0, min(float(duration), max_d))
        self._active[name] = {"start": self._now(), "duration": duration, "intensity": intensity}
        if name == "freeze":
            self._frozen = None   # captured on the next apply()
        return intensity, duration

    def clear(self):
        """The kill key. Drops every effect and forgets the frozen pose."""
        self._active.clear()
        self._frozen = None

    def describe(self):
        """Active effects for the state frame, so the client can show what it caused."""
        t = self._now()
        out = []
        for name, e in self._active.items():
            remaining = e["duration"] - (t - e["start"])
            if remaining <= 0:
                continue        # expired; apply() will drop it on the next tick
            out.append({
                "name": name,
                "intensity": round(e["intensity"], 3),
                "remaining": round(remaining, 2),
            })
        return out

    # ---- the loop ---------------------------------------------------------------

    def apply(self, action, t=None):
        """Modify one joint command. Call once per robot tick, in the robot thread."""
        t = self._now() if t is None else t
        action = dict(action)

        for name in list(self._active):
            e = self._active[name]
            if t - e["start"] >= e["duration"]:
                del self._active[name]
                if name == "freeze":
                    self._frozen = None

        self._history.append((t, dict(action)))
        cutoff = t - FOG_MAX_LAG_S - 0.1
        while len(self._history) > 2 and self._history[0][0] < cutoff:
            self._history.pop(0)

        for name in ORDER:
            e = self._active.get(name)
            if e is not None:
                action = getattr(self, f"_{name}")(action, t - e["start"], e["intensity"], t)

        self._smoothed = dict(action)
        return action

    # ---- the effects themselves -------------------------------------------------

    def _mirror(self, action, age, intensity, t):
        """Shoulder pan is inverted, so left is right. Pan only: mirroring the lift or elbow
        would swing the arm into the table."""
        key = "shoulder_pan.pos"
        if key in action:
            action[key] = -action[key] * intensity + action[key] * (1 - intensity)
        return action

    def _molasses(self, action, age, intensity, t):
        """Sluggish: a low-pass filter toward the previous command."""
        if self._smoothed is None:
            return action
        a = MOLASSES_MAX_ALPHA * intensity
        return {k: (self._smoothed.get(k, v) * a + v * (1 - a)) if k.endswith(".pos") else v
                for k, v in action.items()}

    def _fog(self, action, age, intensity, t):
        """The follower runs behind the leader. Replays a command from `lag` seconds ago."""
        lag = FOG_MAX_LAG_S * intensity
        target = t - lag
        past = None
        for ts, a in self._history:
            if ts <= target:
                past = a
            else:
                break
        return dict(past) if past else action

    def _butterfingers(self, action, age, intensity, t):
        """The jaw cannot fully close. Higher gripper values are more open."""
        key = "gripper.pos"
        if key in action:
            floor = BUTTERFINGERS_OPEN_PCT * intensity
            action[key] = max(action[key], floor)
        return action

    def _earthquake(self, action, age, intensity, t):
        """A few degrees of shake on the joints that cannot drop a held block."""
        amp = EARTHQUAKE_MAX_DEG * intensity
        phase = 2 * math.pi * EARTHQUAKE_HZ * age
        for i, joint in enumerate(EARTHQUAKE_JOINTS):
            key = f"{joint}.pos"
            if key in action:
                wobble = math.sin(phase + i * 2.1) * amp
                wobble += self._rng.uniform(-0.3, 0.3) * amp   # noise, so it reads as real
                action[key] += wobble
        return action

    def _freeze(self, action, age, intensity, t):
        """Hold the pose the arm had when the freeze landed. Ignores the leader entirely."""
        if self._frozen is None:
            self._frozen = dict(action)
        return dict(self._frozen)
