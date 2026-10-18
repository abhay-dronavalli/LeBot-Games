"""The wire format between the robot laptop and Roblox (or any other consumer).

One Python process owns the arm and the camera and serves this protocol over a WebSocket.
Roblox Studio connects *out* to it with HttpService:CreateWebStreamClient, so there is no
middle server: the robot process is the server.

Frames are JSON, one object per WebSocket message, each with a "t" (type) field.

Server -> client
    hello   once, on connect: static geometry the client needs to map mm into its own world
    state   at STATE_HZ: arm pose, blocks, active effects
    pong    reply to ping, for round-trip latency

Client -> server
    event   run a real-world effect on the arm: {"name","intensity","duration"}
    mode    tell the robot side which game mode/level is live (routed to producers)
    place   autonomous mode only: ask the arm to put a block somewhere
    ping    {"id": n} -> pong

Coordinates. Everything the server sends is in the **sheet frame, millimetres**:
origin at the printed sheet's top-left corner, +x right, +y down the page (away from the
arm, which sits at the top), +z up off the paper. The client converts mm to its own units,
so the scale can be retuned without restarting Python. For Roblox (Y-up) that is

    roblox_X = sheet_x * studs_per_mm
    roblox_Z = sheet_y * studs_per_mm
    roblox_Y = sheet_z * studs_per_mm        (or a game-chosen step height per stack level)

Joint angles are degrees, as the follower reports them (not URDF angles, not normalised).
"""

VERSION = 1

# Follower joint order, base to tip. ARM_JOINTS + the gripper.
JOINTS = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

STATE_HZ = 30.0          # state frames per second on the wire
ARM_HZ = 30.0            # how fast the arm producer reads joints
VISION_HZ = 10.0         # perception is segmentation + a homography; it is not 30 Hz

WS_PORT = 8765
VIEWER_PORT = 8766       # the mock-Roblox viewer is served here


def hello(space, source, joints=None, effects=None):
    """Static facts the client needs once, before any state frame."""
    return {
        "t": "hello",
        "v": VERSION,
        "source": source,                 # "mock" | "teleop" | "auto"
        "state_hz": STATE_HZ,
        "joints": joints or JOINTS,
        "effects": effects or [],         # effect names this server will accept
        "space": space,                   # sheet geometry, cube size, suggested scale
    }


def pong(ping_id, ts):
    return {"t": "pong", "id": ping_id, "ts": ts}


def error(message, frame=None):
    return {"t": "error", "message": message, "frame": frame}
