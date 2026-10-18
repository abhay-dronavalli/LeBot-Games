"""Which printed cells hold a cube, decided by geometry instead of by reading the labels.

Why this exists. `bridge/board.py` asks a vision model to read the labels printed on the sheet
and say which cell each cube is in. The model is good at colour and bad at that question, and
no amount of prompting fixes the reason: **a cube sits on top of the label that names its own
cell**. On 2026-10-18 a single cube in B1 covered both the B1 and the A1 label, leaving the
model to infer the cell from a picture in which the evidence is hidden. It inferred a different
answer on different calls - correct on one read, one row off on the next. An unstable answer
is worse than a wrong one, because in Roblox a platform appears to teleport between squares.

Geometry does not have this problem. The sheet's four AprilTags give a pixel->mm homography
with ~1.3 mm of fit error (measured 2026-10-18, all four tags, stable across frames), and the
cells are 57.15 mm across. That is better than an order of magnitude of margin, so the cell a
cube occupies is not a judgement call - it is arithmetic. The model is then only asked what it
is actually good at: what colour is this, and is it one cube or two.

Two deliberate choices, both because the rig moves between locations and the lighting changes
with it (see `robot/scripts/tools/camera_tune.py`):

  * **Cubes are found by chroma distance from the paper, not by an absolute threshold.** The
    paper's own colour is measured from the sheet's own pixels every frame, so white balance
    drift moves the reference along with the scene. Measured on this rig the paper sat at
    a=+10, b=-10 in Lab - not neutral - so assuming grey paper would have biased every pixel.
    Shadows keep the paper's hue and only lose lightness, so a chroma-only distance ignores
    them; that matters because the arm throws a shadow across the sheet on most frames.
  * **A cell is scored by how much of it is covered, not by where a blob's centre is.** Two
    cubes of similar colour sitting in neighbouring cells merge into one blob, and a merged
    blob's centroid is the border between them - the old pipeline's known failure (see the
    note on ACTIVE_COLORS in config.py about teal and light blue at 17:24). Coverage asks each
    cell about itself, so touching cubes never have to be told apart in the first place.

Cells are measured at CUBE_MM/2 above the table, not on the table. A cube photographed from
363 mm up is seen partly from the side, so its outline on the table plane is a smeared shape
leaning away from the camera. Projected at half the cube's height - the height of its own
middle - the outline's centre lands on the cube's true centre: 3 mm from B1's printed centre
in the 2026-10-18 frame, against 18 mm when projected at table height.

    pose = SheetLocalizer().locate(frame)
    for found in occupied_cells(frame, pose):
        print(found.cell, found.coverage, found.bgr)

Known limits, so they are not rediscovered as bugs:

  * **A cube in the gripper, held over the sheet, counts as being on the board.** Geometry
    cannot tell a cube resting on paper from one hanging 150 mm above it; it will be placed in
    whichever cell its silhouette covers, which is not even the cell under it. In practice the
    read happens RELEASE_DELAY_S after the jaw opens, by which time the arm is clearing, so
    this does not bite - but it is why that delay exists and why shortening it is not free.
  * **Anything coloured and not a cube is a cube.** A sticker, a dropped cable or a hand
    resting on the paper will be reported. The sheet polygon keeps the clutter around the mat
    out of it, and the arm itself is dark enough to fall under the chroma threshold.
  * **A cell is occupied or not; it has no depth.** Stack height still comes from the model.
"""

from dataclasses import dataclass

import cv2
import numpy as np

from .config import CUBE_SIZE_MM, SHEET_H_MM, SHEET_W_MM

CUBE_MM = CUBE_SIZE_MM or 48.0

# A cube's own middle: see the module docstring. Projecting the silhouette at this height puts
# its centre on the cube's centre regardless of which way the camera leans.
SAMPLE_HEIGHT_MM = CUBE_MM / 2

# Lab chroma distance from the paper's measured colour before a pixel counts as "not paper".
# Measured 2026-10-18: inside the sheet the paper's own pixels sit under 13 even at the 90th
# percentile while cube pixels sit near 37, and every threshold from 12 to 30 gave the same
# cell and a centre within 1 mm. 20 is the middle of that plateau, chosen so that neither a
# dimmer room nor a more saturated one walks off the edge of it.
CHROMA_T = 20.0

# How much of a cell must be covered before a cube is called present. In the same frame the
# occupied cell scored 0.97 and its most-shadowed neighbour 0.24, so this sits in the middle
# of a wide empty gap rather than near either population.
COVERAGE_T = 0.5

# Speckle removal. Printed grid lines and label text are thin and dark, and survive the chroma
# test only where JPEG ringing tints them; an open of this radius clears them while taking a
# negligible bite out of a 160 px cube.
OPEN_PX = 9

MIN_COLOR_PX = 200      # fewer cube pixels than this and the median colour is noise


@dataclass
class Found:
    cell: str
    coverage: float         # 0..1 of the cell's own area that is cube
    bgr: tuple | None       # median colour of the cube pixels, or None if too few to trust

    @property
    def color_hint(self):
        """The median colour as a plain (b, g, r) tuple of ints, for logging and overlays."""
        return None if self.bgr is None else tuple(int(v) for v in self.bgr)


def _poly(pose, corners_mm, height_mm=0.0):
    return pose.to_image(np.asarray(corners_mm, np.float64), height_mm=height_mm).astype(np.int32)


def sheet_polygon(pose, margin_mm=0.0):
    """The paper's outline in image pixels, as a 4-point polygon."""
    m = margin_mm
    return _poly(pose, [(-m, -m), (SHEET_W_MM + m, -m),
                        (SHEET_W_MM + m, SHEET_H_MM + m), (-m, SHEET_H_MM + m)])


def cell_polygon(pose, centre_mm, cell_mm, height_mm=SAMPLE_HEIGHT_MM):
    """One grid cell's square in image pixels, measured at `height_mm` above the table."""
    h = cell_mm / 2.0
    x, y = centre_mm
    return _poly(pose, [(x - h, y - h), (x + h, y - h), (x + h, y + h), (x - h, y + h)], height_mm)


def cube_mask(frame_bgr, pose):
    """Pixels inside the sheet that are not the paper. Returns (mask, paper_ab).

    `paper_ab` is the paper's measured Lab chroma centre, handy for a caller that wants to say
    how far the white balance has drifted.
    """
    lab = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2LAB)
    a = lab[..., 1].astype(np.float32) - 128.0
    b = lab[..., 2].astype(np.float32) - 128.0

    paper = np.zeros(frame_bgr.shape[:2], np.uint8)
    cv2.fillPoly(paper, [sheet_polygon(pose)], 1)
    if paper.sum() < 1000:                      # the sheet is barely in frame; nothing to say
        return np.zeros_like(paper), (0.0, 0.0)

    sel = paper.astype(bool)
    pa, pb = float(np.median(a[sel])), float(np.median(b[sel]))
    chroma = np.sqrt((a - pa) ** 2 + (b - pb) ** 2)

    mask = ((chroma > CHROMA_T) & sel).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((OPEN_PX, OPEN_PX), np.uint8))
    return mask, (pa, pb)


def occupied_cells(frame_bgr, pose, cell_centres, cell_mm, mask=None):
    """Which of `cell_centres` hold a cube. `cell_centres` maps "B1" -> (x_mm, y_mm).

    Returns a list of `Found`, in the order the cells were given.
    """
    if mask is None:
        mask, _ = cube_mask(frame_bgr, pose)
    out = []
    h_img, w_img = mask.shape
    for cell, centre in cell_centres.items():
        poly = cell_polygon(pose, centre, cell_mm)
        # Work inside the cell's bounding box. A full-frame buffer per cell is twelve 2-megapixel
        # allocations per read for twelve little squares, and it showed: half a second of the
        # budget went here, next to a model call that is the whole point of the read.
        x, y, w, h = cv2.boundingRect(poly)
        x0, y0 = max(x, 0), max(y, 0)
        x1, y1 = min(x + w, w_img), min(y + h, h_img)
        if x1 <= x0 or y1 <= y0:                # the cell is off the edge of the image
            continue
        area = np.zeros((y1 - y0, x1 - x0), np.uint8)
        cv2.fillPoly(area, [poly - [x0, y0]], 1)
        total = int(area.sum())
        if total <= 0:
            continue
        hit = area.astype(bool) & (mask[y0:y1, x0:x1] > 0)
        coverage = float(hit.sum()) / total
        if coverage < COVERAGE_T:
            continue
        px = frame_bgr[y0:y1, x0:x1][hit]
        bgr = tuple(np.median(px, axis=0)) if len(px) >= MIN_COLOR_PX else None
        out.append(Found(cell, round(coverage, 3), bgr))
    return out


def annotate(frame_bgr, pose, cell_centres, cell_mm, found, margin_mm=14.0):
    """Crop to the sheet and draw the grid, so the model sees the board and nothing else.

    The crop is the point. A 1920-wide frame is mostly table, mat and cable; the sheet is about
    a quarter of it, so downscaling to the model's width spends most of the pixels on things
    the question is not about and shrinks the printed labels toward illegible. Cropping first
    means the whole budget goes to the board.

    Occupied cells are outlined thickly and labelled outside their own square, which is the
    other half of the fix: the label naming a cell is no longer underneath the cube that makes
    the cell worth naming.
    """
    vis = frame_bgr.copy()
    # Only the occupied cells are drawn. An outline for every cell was tried first and is
    # actively misleading: these squares are measured at cube height, so an empty one does not
    # sit on its own printed square and the picture ends up with two grids a centimetre apart.
    # The printed grid is already in the photo for context; what the model needs added is which
    # squares matter and what they are called.
    for f in found:
        poly = cell_polygon(pose, cell_centres[f.cell], cell_mm)
        cv2.polylines(vis, [poly], True, (0, 230, 0), 3)
        x, y = poly[0]                  # the cell's far corner, nudged out so text clears the cube
        for colour, weight in (((0, 0, 0), 5), ((0, 230, 0), 2)):
            cv2.putText(vis, f.cell, (int(x) - 4, int(y) - 8), cv2.FONT_HERSHEY_SIMPLEX,
                        0.9, colour, weight, cv2.LINE_AA)

    poly = sheet_polygon(pose, margin_mm)
    x, y, w, h = cv2.boundingRect(poly)
    x, y = max(x, 0), max(y, 0)
    w, h = min(w, vis.shape[1] - x), min(h, vis.shape[0] - y)
    if w < 50 or h < 50:                        # degenerate pose: better the whole frame
        return vis
    return vis[y:y + h, x:x + w]
