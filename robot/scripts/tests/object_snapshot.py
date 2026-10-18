"""Detect everyday objects on the sheet and report them in sheet mm with graspability.

    python -m robot.scripts.tests.object_snapshot              # live camera
    python -m robot.scripts.tests.object_snapshot frame.png    # a saved frame

Needs an empty-sheet reference first (capture_reference). Prints, per object, its centre in
sheet mm, its minor/major axis in mm, and whether the SO-101 jaw can span it.
"""

import sys
import time

import cv2
import numpy as np

from robot.perception import objects
from robot.perception.camera import Camera
from robot.perception.config import ROOT
from robot.perception.scene import sheet_roi_mask
from robot.perception.sheet import SheetLocalizer


def main():
    live = len([a for a in sys.argv[1:] if not a.startswith("-")]) == 0
    if live:
        with Camera() as cam:
            frame = cam.read()
    else:
        frame = cv2.imread(sys.argv[1])
        if frame is None:
            raise SystemExit(f"Can't read {sys.argv[1]}")

    pose = SheetLocalizer().locate(frame)
    if pose is None:
        raise SystemExit("Sheet not found: need at least 2 AprilTags visible.")

    roi = sheet_roi_mask(pose, frame.shape)
    dets = objects.detect(frame, roi_mask=roi)
    if not dets:
        print("No objects found. Is anything on the sheet? Is the reference stale?")

    annotated = frame.copy()
    print(f"{'#':<3} {'centre mm':<18} {'minor':>7} {'major':>7}  {'fill':>5}  graspable")
    for i, d in enumerate(dets, 1):
        cx, cy = pose.to_sheet(np.array([d.center_px], np.float32))[0]
        minor, major = objects.grasp_span_mm(d.contour, pose)
        ok = objects.graspable(minor)
        print(f"{i:<3} ({cx:7.1f},{cy:7.1f})  {minor:7.1f} {major:7.1f}  {d.score:5.2f}  "
              f"{'yes' if ok else 'NO - too wide'}")
        color = (0, 200, 0) if ok else (0, 0, 220)
        cv2.drawContours(annotated, [d.contour.astype(np.int32)], -1, color, 2)
        cv2.putText(annotated, f"{i}", tuple(np.int32(d.center_px)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, color, 2)

    out = ROOT / "outputs" / "objects_latest.png"
    out.parent.mkdir(exist_ok=True)
    cv2.imwrite(str(out), annotated)
    if live:
        snaps = ROOT / "outputs" / "snapshots"
        snaps.mkdir(exist_ok=True)
        cv2.imwrite(str(snaps / f"{time.strftime('%Y%m%d_%H%M%S')}_objects_raw.png"), frame)
    print(f"\nJaw spans {objects.JAW_SPAN_MM:.0f} mm, needs {objects.JAW_MARGIN_MM:.0f} mm "
          f"clearance each side -> max object {objects.JAW_SPAN_MM - 2*objects.JAW_MARGIN_MM:.0f} mm")
    print("Annotated:", out)


if __name__ == "__main__":
    main()
