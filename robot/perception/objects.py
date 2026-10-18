"""Find everyday objects on the sheet by differencing against a reference empty frame.

segment.detect finds things more *colourful* than the paper, which works for painted cubes
but misses a white salt shaker on white paper. For arbitrary household objects the reliable
signal is "different from how the empty sheet looked": the sheet is taped down and the camera
is fixed, so one reference frame stays valid for the whole session.

Returns detect_color.Detection, so scene.build_scene can use it like the other detectors.
Names come from scene naming (a vision model), not from here: this module only finds things.

    python -m robot.scripts.tests.capture_reference      # once, empty sheet
    python -m robot.scripts.tests.object_snapshot        # objects on the sheet

Graspability: the SO-101 jaw spans about CUBE_MM (48 mm) at GRIPPER_OPEN. An object is
reachable by the jaw when its *minor* axis fits, since the arm can yaw to approach across
the narrow side.
"""

import cv2
import numpy as np

from .config import ROOT
from .detect_color import Detection

REFERENCE_PATH = ROOT / "calibration" / "empty_sheet.png"

# The threshold follows the room, like segment.py's chroma test: a fixed Lab distance either
# misses white-on-white (a salt shaker reads only ~15 from paper) or floods on lighting drift.
# Empty sheet pixels cluster near zero, so median + K*MAD of the difference tracks the noise.
DIFF_FLOOR = 9.0         # never trust a difference smaller than this (sensor noise)
DIFF_MAD_K = 7.0         # ...or median + this many MADs, whichever is larger
# Thresholds in mm, not pixels: a 6 mm spoon handle is only ~180 px at 2.5 px/mm and a
# pixel floor of 900 silently drops everything narrower than ~21 mm.
MIN_AREA_MM2 = 12.0      # a 4 mm diameter handle is ~13 mm2
MIN_AREA_PX_FLOOR = 60   # ...but never trust a blob this small in pixels, whatever the scale
MORPH_MM = 2.0           # closing/opening kernel in mm; a 7 px kernel erodes a thin handle away
SHADOW_V_DROP = 0.75     # a region only *darker* than the reference by less than this ratio, with
                         # no chroma change, is a shadow rather than an object
JAW_SPAN_MM = 48.0       # SO-101 jaw opening at GRIPPER_OPEN (robot/skills.py CUBE_MM)
JAW_MARGIN_MM = 4.0      # the fixed jaw needs this much clearance outside the object face

# Where to close the jaw on a known object, in mm above the table. Mapping a tall object's
# blob at table height is wrong: the camera sits CAMERA_HEIGHT_MM up, so a 120 mm handle
# 80 mm off the camera axis lands 22 mm sideways, far past the ~5.5 mm grasp tolerance.
# Height per object is a catalog, as the cube pipeline used a fixed 24 mm mid-cube height.
GRASP_HEIGHTS_MM = {
    "spoon_in_cup": 110.0,   # the handle well above the cup rim
    "salt_shaker": 30.0,
    "pill_bottle": 35.0,
    "marker": 10.0,          # lying down
    "cube": 24.0,            # mid-cube, as in the Apprentice pipeline
}
DEFAULT_GRASP_HEIGHT_MM = 20.0


def px_per_mm(pose):
    """Image scale at table height, from the sheet mapping itself."""
    a, b = pose.to_image([(20.0, 20.0), (120.0, 20.0)])
    return float(np.linalg.norm(np.asarray(b) - np.asarray(a)) / 100.0)


def center_mm(det, pose, height_mm=DEFAULT_GRASP_HEIGHT_MM):
    """Blob centroid in sheet mm, mapped at the height the jaw will close at."""
    return tuple(pose.to_sheet(np.array([det.center_px], np.float32), height_mm=height_mm)[0])


def grasp_height_for(name, default=DEFAULT_GRASP_HEIGHT_MM):
    return GRASP_HEIGHTS_MM.get(name, default)


def load_reference(path=REFERENCE_PATH):
    if not path.exists():
        raise FileNotFoundError(
            f"No empty-sheet reference at {path}. Run: "
            "python -m robot.scripts.tests.capture_reference"
        )
    img = cv2.imread(str(path))
    if img is None:
        raise ValueError(f"Could not read reference image {path}")
    return img


def _shadow_mask(frame_lab, ref_lab):
    """True where the pixel only got darker, with no colour change: a cast shadow."""
    dl = frame_lab[:, :, 0].astype(np.int16) - ref_lab[:, :, 0].astype(np.int16)
    dchroma = np.linalg.norm(
        frame_lab[:, :, 1:].astype(np.int16) - ref_lab[:, :, 1:].astype(np.int16), axis=2
    )
    darker = dl < 0
    ratio = np.ones_like(dl, dtype=np.float32)
    ref_l = np.maximum(ref_lab[:, :, 0].astype(np.float32), 1.0)
    ratio = frame_lab[:, :, 0].astype(np.float32) / ref_l
    return darker & (ratio > SHADOW_V_DROP) & (dchroma < 10)


def object_mask(frame_bgr, reference_bgr, roi_mask=None, ppm=None):
    """Pixels that differ from the empty sheet, shadows and noise removed."""
    if frame_bgr.shape != reference_bgr.shape:
        reference_bgr = cv2.resize(reference_bgr, (frame_bgr.shape[1], frame_bgr.shape[0]))

    blur = lambda im: cv2.GaussianBlur(im, (5, 5), 0)
    frame_lab = cv2.cvtColor(blur(frame_bgr), cv2.COLOR_BGR2LAB)
    ref_lab = cv2.cvtColor(blur(reference_bgr), cv2.COLOR_BGR2LAB)

    dist = np.linalg.norm(frame_lab.astype(np.int16) - ref_lab.astype(np.int16), axis=2)

    sample = dist[roi_mask > 0] if roi_mask is not None else dist.ravel()
    med = float(np.median(sample))
    mad = float(np.median(np.abs(sample - med))) or 1.0
    threshold = max(DIFF_FLOOR, med + DIFF_MAD_K * mad)
    mask = (dist > threshold).astype(np.uint8) * 255
    mask[_shadow_mask(frame_lab, ref_lab)] = 0

    if roi_mask is not None:
        mask &= roi_mask

    kpx = max(3, int(round(MORPH_MM * ppm))) if ppm else 5
    kpx += kpx % 2 == 0  # keep it odd
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kpx, kpx))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, k)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, k)
    return mask


def detect(frame_bgr, names=None, roi_mask=None, reference_bgr=None, pose=None, tags=None):
    """Find objects on the sheet. Signature matches detect_color.detect / segment.detect."""
    if reference_bgr is None:
        reference_bgr = load_reference()
    ppm = px_per_mm(pose) if pose is not None else None
    min_area = max(MIN_AREA_PX_FLOOR, MIN_AREA_MM2 * ppm * ppm) if ppm else 900
    mask = object_mask(frame_bgr, reference_bgr, roi_mask, ppm)

    n, labels, stats, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
    out = []
    for i in range(1, n):
        area = stats[i, cv2.CC_STAT_AREA]
        if area < min_area:
            continue
        blob = (labels == i).astype(np.uint8)
        contours, _ = cv2.findContours(blob, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not contours:
            continue
        contour = max(contours, key=cv2.contourArea).reshape(-1, 2)
        x0 = stats[i, cv2.CC_STAT_LEFT]
        y0 = stats[i, cv2.CC_STAT_TOP]
        x1 = x0 + stats[i, cv2.CC_STAT_WIDTH]
        y1 = y0 + stats[i, cv2.CC_STAT_HEIGHT]
        rect_area = max(cv2.minAreaRect(contour)[1][0] * cv2.minAreaRect(contour)[1][1], 1.0)
        out.append(Detection(
            name=f"object_{len(out) + 1}",
            bbox_px=(int(x0), int(y0), int(x1), int(y1)),
            center_px=(float(centroids[i][0]), float(centroids[i][1])),
            score=float(min(area / rect_area, 1.0)),
            contour=contour,
        ))
    out.sort(key=lambda d: -cv2.contourArea(d.contour))
    return out


def grasp_span_mm(contour_px, pose):
    """(minor, major) axis of the object in sheet mm, at table height.

    The jaw closes across the minor axis, so that is the one that has to fit.
    """
    xy = pose.to_sheet(contour_px.astype(np.float32), height_mm=0.0)
    rect = cv2.minAreaRect(np.asarray(xy, dtype=np.float32))
    w, h = rect[1]
    return (float(min(w, h)), float(max(w, h)))


def graspable(minor_mm):
    """Can the jaw take this object across its narrow side?"""
    return minor_mm + 2 * JAW_MARGIN_MM <= JAW_SPAN_MM
