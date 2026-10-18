"""Save one empty-sheet frame as the reference for everyday-object detection.

Run this ONCE per session, with the sheet taped down, the camera fixed, the lighting set
and NOTHING on the sheet (keep the arm parked out of view). objects.detect compares every
later frame to this one. Re-run it if the camera moves, the sheet moves, or the lights change.

    python -m robot.scripts.tests.capture_reference
    python -m robot.scripts.tests.capture_reference --force   # overwrite an existing one
"""

import sys

import cv2

from robot.perception.camera import Camera
from robot.perception.objects import REFERENCE_PATH
from robot.perception.sheet import SheetLocalizer


def main():
    force = "--force" in sys.argv
    if REFERENCE_PATH.exists() and not force:
        raise SystemExit(f"{REFERENCE_PATH} already exists. Pass --force to replace it.")

    with Camera() as cam:
        frame = cam.read()

    pose = SheetLocalizer().locate(frame)
    if pose is None:
        raise SystemExit(
            "Sheet not found (need at least 2 AprilTags visible). Fix the view before "
            "capturing a reference, or the mapping to arm coordinates will not work."
        )

    tags = SheetLocalizer().detect_tags(frame)
    REFERENCE_PATH.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(REFERENCE_PATH), frame)
    print(f"Reference saved: {REFERENCE_PATH}")
    print(f"Tags visible: {sorted(tags) if hasattr(tags, '__iter__') else tags}")
    print("\nThe sheet must now stay put. Anything that changes the empty view -- moving the")
    print("camera or sheet, or a big lighting change -- needs a new reference (--force).")


if __name__ == "__main__":
    main()
