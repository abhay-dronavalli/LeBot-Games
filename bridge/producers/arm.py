"""One joint reading becomes one arm frame, in the sheet frame, for the wire.

Every producer (mock, teleop, autonomous) ends up here, so Roblox sees the same shape no
matter what is driving the arm.

The heavy lifting already exists in `robot.workspace.Workspace`: it holds the fitted
sheet-to-base transform and the joint zero offsets, and `arm_points_sheet` returns the arm as
a stick figure of joint centres plus the jaw tips, in sheet millimetres with heights above the
paper. That is exactly a Sky Arm rig's input, so this module is a formatter, not a solver.
"""

from robot.kinematics import ARM_JOINTS

# The follower reports six joints; ARM_JOINTS is the five that move the tip (no gripper).
WIRE_JOINTS = ARM_JOINTS + ["gripper"]

# Named so a Roblox rig can bind each Motor6D to a segment instead of guessing by index.
# arm_points_sheet returns one point per ARM_JOINTS joint centre, then the jaw tips.
POINT_NAMES = ARM_JOINTS + ["tip"]


def reading_from_action(action):
    """A LeRobot action/observation ({"shoulder_pan.pos": 12.1, ...}) as a plain dict."""
    return {k.removesuffix(".pos"): float(v) for k, v in action.items() if k.endswith(".pos")}


def arm_frame(ws, reading, extra=None):
    """The "arm" object of a state frame.

    ws:      a robot.workspace.Workspace
    reading: follower degrees, {"shoulder_pan": .., ..., "gripper": ..}

    Heights are millimetres above the paper, so z=0 is the sheet surface and a block resting
    on it has its base at 0. Roblox converts mm to studs itself.
    """
    arm_only = {j: reading[j] for j in ARM_JOINTS if j in reading}
    points = [
        {"name": name, "x": round(float(xy[0]), 1), "y": round(float(xy[1]), 1), "z": round(float(h), 1)}
        for name, (xy, h) in zip(POINT_NAMES, ws.arm_points_sheet(arm_only))
    ]
    frame = {
        "joints": {j: round(float(reading[j]), 2) for j in WIRE_JOINTS if j in reading},
        "points": points,
        "tip": {k: points[-1][k] for k in ("x", "y", "z")},
    }
    if extra:
        frame.update(extra)
    return frame
