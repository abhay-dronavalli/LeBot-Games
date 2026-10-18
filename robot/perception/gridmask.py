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

# A cell is scored over the middle of its square, not the whole of it. A 48 mm cube in a 57 mm
# cell leaves almost no gap, and what the camera sees of it is wider than the cube itself - the
# silhouette of the B1 cube measured 65x83 mm - so a cube spills over its own borders into its
# neighbours. Measured with six cubes on the sheet (2026-10-18), scoring whole cells left EMPTY
# A2 at 0.46 against a 0.50 threshold: one sloppy placement from a phantom block. Scoring the
# middle 75% pushes every real cube to 0.97+ and costs nothing, because a cube is only in a cell
# at all if it covers the middle of it.
CELL_SAMPLE = 0.75

# Lab chroma distance from the paper's measured colour before a pixel counts as "not paper".
# Measured 2026-10-18: inside the sheet the paper's own pixels sit under 13 even at the 90th
# percentile while cube pixels sit near 37, and every threshold from 12 to 30 gave the same
# cell and a centre within 1 mm. 20 is the middle of that plateau, chosen so that neither a
# dimmer room nor a more saturated one walks off the edge of it.
CHROMA_T = 20.0

# How much of that middle must be covered before a cube is called present. With six cubes out,
# every occupied cell scored 0.97 or better and the worst empty one 0.29, so this sits in a
# wide gap. It is deliberately nearer the empty side: a cube has to be placed about 14 mm off
# centre - half way out of its cell - before it drops this low, while a phantom needs an empty
# cell to gain 0.31.
COVERAGE_T = 0.6

# Padding on the silhouette subtracted once a cube is claimed, mm. Covers the few mm the mask
# bleeds past the cube's true outline through shadow and JPEG ringing.
CLAIM_PAD_MM = 4.0

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


def cube_silhouette(pose, centre_mm, pad_mm=CLAIM_PAD_MM, top_mm=None):
    """Everything a cube standing in this cell could darken: its base square and its top
    square, projected and hulled together.

    Deliberately a single cube's height and not a stack's. Erasing a two-cube column was tried
    and is worse: the taller hull reaches across into the next cell and eats the evidence for a
    cube that is really there (B2 fell from 1.00 to 0.84 in the six-cube frame).
    """
    top = CUBE_MM if top_mm is None else top_mm
    x, y = centre_mm
    h = CUBE_MM / 2 + pad_mm
    sq = np.float64([(x - h, y - h), (x + h, y - h), (x + h, y + h), (x - h, y + h)])
    both = np.vstack([pose.to_image(sq, height_mm=0.0),
                      pose.to_image(sq, height_mm=top + pad_mm)])
    return cv2.convexHull(both.astype(np.int32))


def _coverage(mask, frame_bgr, pose, centre, cell_mm):
    """(coverage, median bgr) for one cell's middle. (0.0, None) if it is out of frame."""
    poly = cell_polygon(pose, centre, cell_mm * CELL_SAMPLE)
    h_img, w_img = mask.shape
    # Work inside the cell's bounding box. A full-frame buffer per cell is twelve 2-megapixel
    # allocations per read for twelve little squares, and it showed: half a second of the
    # budget went here, next to a model call that is the whole point of the read.
    x, y, w, h = cv2.boundingRect(poly)
    x0, y0 = max(x, 0), max(y, 0)
    x1, y1 = min(x + w, w_img), min(y + h, h_img)
    if x1 <= x0 or y1 <= y0:
        return 0.0, None
    area = np.zeros((y1 - y0, x1 - x0), np.uint8)
    cv2.fillPoly(area, [poly - [x0, y0]], 1)
    total = int(area.sum())
    if total <= 0:
        return 0.0, None
    hit = area.astype(bool) & (mask[y0:y1, x0:x1] > 0)
    px = frame_bgr[y0:y1, x0:x1][hit]
    bgr = tuple(np.median(px, axis=0)) if len(px) >= MIN_COLOR_PX else None
    return float(hit.sum()) / total, bgr


def occupied_cells(frame_bgr, pose, cell_centres, cell_mm, mask=None):
    """Which of `cell_centres` hold a cube. `cell_centres` maps "B1" -> (x_mm, y_mm).

    Cells are claimed one at a time, strongest first, and each claimed cube's silhouette is
    erased from the mask before the rest are scored again. Scoring every cell once against the
    same mask does not work: a cube is seen partly from the side, so it darkens a slice of its
    downhill neighbour too, and with six cubes out that left an empty cell at 0.46 - close
    enough to the threshold to invent a block. Subtracting a cube once it is accounted for
    drops the worst empty cell to 0.29 and lifts every real one to 0.97 or better.

    Returns a list of `Found`, ordered by cell name.
    """
    if mask is None:
        mask, _ = cube_mask(frame_bgr, pose)
    work = mask.copy()
    out = []
    left = dict(cell_centres)
    # Scores are kept between rounds and only recomputed where the mask actually changed.
    # Rescoring all twelve every round is twelve times the work for a handful of cells that
    # could have moved, and it showed: 0.70 s against 0.26 s for the same six cubes.
    score = {c: _coverage(work, frame_bgr, pose, centre, cell_mm)
             for c, centre in left.items()}
    while left:
        cell = max(left, key=lambda c: score[c][0])
        coverage, bgr = score[cell]
        if coverage < COVERAGE_T:
            break
        out.append(Found(cell, round(coverage, 3), bgr))
        hull = cube_silhouette(pose, left.pop(cell))
        cv2.fillPoly(work, [hull], 0)
        hx, hy, hw, hh = cv2.boundingRect(hull)
        for c, centre in left.items():
            cx, cy, cw, ch = cv2.boundingRect(cell_polygon(pose, centre, cell_mm * CELL_SAMPLE))
            if cx < hx + hw and hx < cx + cw and cy < hy + hh and hy < cy + ch:
                score[c] = _coverage(work, frame_bgr, pose, centre, cell_mm)
    return sorted(out, key=lambda f: f.cell)


def overlay(frame_bgr, pose, cell_centres, cell_mm, margin_mm=14.0):
    """Crop to the sheet and redraw the grid, deciding nothing about what is on it.

    Everything here comes from the four tags, so it is the same picture the camera took with
    the board made easier to read. Nothing in it is an opinion about where a cube is.

    Two things it fixes for a model that has to answer the position question itself:

      * **The crop.** The sheet is about a quarter of a 1920-wide frame and the rest is table,
        mat and cable. Downscaling the whole frame to the model's width spends most of the
        pixels on things the question is not about and shrinks the printed labels toward
        illegible; cropping first gives the board the whole budget.
      * **The labels.** A cube sits on top of the label that names its own cell, so in the raw
        photo the evidence for the answer is underneath the thing being asked about. These are
        drawn at each cell's corner instead of its centre, where a cube does not reach, so
        every cell stays named however the board is filled.

    The grid is drawn on the table plane, so it lands exactly on the printed grid rather than
    floating above it.
    """
    vis = frame_bgr.copy()
    for cell, centre in cell_centres.items():
        poly = cell_polygon(pose, centre, cell_mm, height_mm=0.0)
        cv2.polylines(vis, [poly], True, (60, 200, 60), 2, cv2.LINE_AA)
        x, y = poly[0]                              # the cell's top-left corner on the paper
        for colour, weight in (((255, 255, 255), 5), ((20, 140, 20), 2)):
            cv2.putText(vis, cell, (int(x) + 6, int(y) + 26), cv2.FONT_HERSHEY_SIMPLEX,
                        0.7, colour, weight, cv2.LINE_AA)
    return _crop_to_sheet(vis, pose, margin_mm)


def _crop_to_sheet(vis, pose, margin_mm):
    x, y, w, h = cv2.boundingRect(sheet_polygon(pose, margin_mm))
    x, y = max(x, 0), max(y, 0)
    w, h = min(w, vis.shape[1] - x), min(h, vis.shape[0] - y)
    if w < 50 or h < 50:                            # degenerate pose: better the whole frame
        return vis
    return vis[y:y + h, x:x + w]


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

    return _crop_to_sheet(vis, pose, margin_mm)
