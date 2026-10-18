"""The overhead camera, in its own thread, feeding the block tracker.

Separate from the arm loop on purpose. `build_scene` is a homography fit plus colour
segmentation over a 1920x1080 frame; it is nowhere near 30 Hz, and the arm must not wait for
it. Blocks therefore update slower than the arm, and the state frame carries `blocks_age` so
the client knows how fresh they are.

Naming. `build_scene(naming="auto")` asks a vision model when it is unsure what colour a
block is, which is far too slow for a loop and costs a network round trip. Here it runs with
naming="local", which uses the session's colour memory only. Build that memory first with the
colour calibration script; otherwise blocks arrive with rough guessed colours, and since the
tracker keys identity on *position* rather than colour, a wrong colour is cosmetic.
"""

import threading
import time

from robot.perception import scene as scene_mod
from robot.perception import sheet as sheet_mod
from robot.perception.camera import Camera

HZ = 10.0
NAMING = "local"           # never call the vision model inside the loop


def run(bus, tracker, stop, hz=HZ):
    localizer = sheet_mod.SheetLocalizer()
    period = 1.0 / hz
    lost = 0
    with Camera() as cam:
        print(f"  vision: camera open, {hz:g} Hz")
        while not stop.is_set():
            loop = time.perf_counter()
            try:
                frame = cam.read()
                scene, pose, _ = scene_mod.build_scene(frame, localizer, naming=NAMING)
                if scene is None:
                    lost += 1
                    if lost in (1, 50):
                        print("  vision: sheet not visible (need 2+ AprilTags)")
                    bus.note("sheet", "not visible")
                else:
                    lost = 0
                    bus.note("sheet", {"tags": scene["sheet"]["tags"],
                                       "fit_error_mm": scene["sheet"]["fit_error_mm"]})
                    # The arm pose is whatever the robot thread published last; the tracker
                    # needs it to decide what is held.
                    arm = bus.arm()
                    bus.publish_blocks(tracker.update(scene["objects"], arm, time.time()))
            except Exception as e:
                bus.note("vision_error", f"{type(e).__name__}: {e}")
                time.sleep(0.2)

            sleep = period - (time.perf_counter() - loop)
            if sleep > 0:
                time.sleep(sleep)


def start(bus, tracker, stop, hz=HZ):
    t = threading.Thread(target=run, args=(bus, tracker, stop), kwargs={"hz": hz},
                         name="vision", daemon=True)
    t.start()
    return t
