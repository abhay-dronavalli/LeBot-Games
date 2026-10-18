"""Generate the printable grid sheet, the printable mat tags, and the matching spec JSON.

The old `Apprentice_AprilTag_Grid.pdf` put four AprilTags *on* the sheet, which cost two
bands of paper and left room for only a 3x3 grid. Moving the tags onto the mat frees the
whole sheet for grid, and turning the sheet landscape fits a wider one:

    portrait  Letter, tags on sheet:   3 rows x 3 cols =  9 cells
    landscape Letter, tags on the mat: 3 rows x 4 cols = 12 cells

Four columns is the limit: five would need 285.8 mm across a 279.4 mm page. Three rows is the
limit: four would need 228.6 mm down a 215.9 mm page. The arm could reach a wider grid (its
envelope allows 3 x 7), so the paper is what caps this, not the robot. For a bigger play area,
print two sheets and lay them side by side.

    python -m robot.scripts.make_sheet                 # 3x4 landscape Letter, writes the spec
    python -m robot.scripts.make_sheet --rows 3 --cols 7 --paper 2xletter
    python -m robot.scripts.make_sheet --no-spec       # just the printables

Output lands in `robot/assets/`. SVG, not PDF: it carries exact millimetre units, needs no
dependency, and prints true size from any browser. **Check the scale bar with a ruler after
printing** - a printer set to "fit to page" silently shrinks everything by a few percent, and
every position in this project would then be wrong by that factor.

Tag placement. Each tag's inner corner butts against a corner of the sheet, so the sheet is
its own alignment jig and there is nothing to measure. Tape the tags to the mat first, then
the sheet inside them.
"""

import argparse
import json
import shutil
import time
from pathlib import Path

import cv2
import numpy as np

ASSETS = Path(__file__).resolve().parent.parent / "assets"

PAPERS = {           # width, height in mm, portrait
    "letter": (215.9, 279.4),
    "a4": (210.0, 297.0),
    "2xletter": (431.8, 279.4),     # two Letter sheets side by side, short edges touching
    "a3": (297.0, 420.0),
}

CELL_MM = 57.15                      # 2.25 in, unchanged: the cube is 48 mm
TAG_MM = 31.75                       # 1.25 in, unchanged
DICTIONARY = "DICT_APRILTAG_36h11"
SCALE_BAR_MM = 50.8                 # 2.00 in, the print check
ROW_LETTERS = "ABCDEFGH"

LINE_MM = 0.3
EDGE_MM = 0.6
# Keep every annotation this far inside the page. Printers cannot mark the outer few mm,
# and anything closer is silently clipped.
SAFE_MM = 12.0


def tag_bits(tag_id, dictionary=DICTIONARY):
    """The tag as a boolean grid, True = white. 36h11 is 6 data bits plus a 1-bit border."""
    d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, dictionary))
    n = d.markerSize + 2
    img = cv2.aruco.generateImageMarker(d, tag_id, n)
    return (np.asarray(img) > 127), n


def tag_svg(tag_id, x, y, size_mm, dictionary=DICTIONARY):
    """A tag drawn as one black square plus white rects for the light bits. Vector, so it
    stays crisp at any print resolution, unlike an embedded bitmap."""
    bits, n = tag_bits(tag_id, dictionary)
    bit = size_mm / n
    out = [f'<rect x="{x:.4f}" y="{y:.4f}" width="{size_mm:.4f}" height="{size_mm:.4f}" fill="#000"/>']
    for r in range(n):
        for c in range(n):
            if bits[r, c]:
                # Overlap each white bit very slightly, or printer anti-aliasing leaves grey
                # seams between them that can round the tag's bit pattern to the wrong id.
                out.append(
                    f'<rect x="{x + c * bit - 0.01:.4f}" y="{y + r * bit - 0.01:.4f}" '
                    f'width="{bit + 0.02:.4f}" height="{bit + 0.02:.4f}" fill="#fff"/>')
    return "\n".join(out)


def grid_sheet_svg(pw, ph, rows, cols, cell, gap, tag_mm):
    """The grid sheet. No tags on it: they live on the mat."""
    gw, gh = cols * cell, rows * cell
    ox, oy = (pw - gw) / 2, (ph - gh) / 2

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{pw}mm" height="{ph}mm" '
         f'viewBox="0 0 {pw} {ph}">',
         '<rect width="100%" height="100%" fill="#fff"/>',
         '<g stroke="#000" fill="none" stroke-linecap="square">']

    # Cell lines, then a heavier border so the grid's extent is unambiguous.
    for c in range(cols + 1):
        x = ox + c * cell
        s.append(f'<line x1="{x:.4f}" y1="{oy:.4f}" x2="{x:.4f}" y2="{oy + gh:.4f}" '
                 f'stroke-width="{LINE_MM}"/>')
    for r in range(rows + 1):
        y = oy + r * cell
        s.append(f'<line x1="{ox:.4f}" y1="{y:.4f}" x2="{ox + gw:.4f}" y2="{y:.4f}" '
                 f'stroke-width="{LINE_MM}"/>')
    s.append(f'<rect x="{ox:.4f}" y="{oy:.4f}" width="{gw:.4f}" height="{gh:.4f}" '
             f'stroke-width="{EDGE_MM}"/>')
    s.append("</g>")

    # Cell names. The robot's convention: letter is the row, A nearest the arm; number is the
    # column, 1 to n left to right seen from above. See robot/README.md decision 1.
    s.append('<g font-family="Helvetica,Arial,sans-serif" fill="#b0b0b0" '
             'text-anchor="middle" font-size="7">')
    for r in range(rows):
        for c in range(cols):
            s.append(f'<text x="{ox + (c + .5) * cell:.4f}" y="{oy + (r + .5) * cell + 2.5:.4f}">'
                     f'{ROW_LETTERS[r]}{c + 1}</text>')
    s.append("</g>")

    # Which edge the arm sits behind. Printing this sheet 180 degrees out would mirror every
    # cell name with no error anywhere, so it is worth the ink.
    s.append(f'<g font-family="Helvetica,Arial,sans-serif" fill="#000" text-anchor="middle">'
             f'<text x="{pw / 2:.4f}" y="{max(oy - 6, 5):.4f}" font-size="5" '
             f'letter-spacing="1.5">ARM THIS SIDE &#8593; &#8593; &#8593;</text></g>')

    # Which mat tag belongs at which corner. No bracket is drawn at the corner itself: the
    # sheet's corners are the paper's corners, which are visible without being printed, and a
    # mark that close to the edge is clipped by the printer anyway.
    s.append('<g font-family="Helvetica,Arial,sans-serif" fill="#999" font-size="3.2">')
    for tx, ty, anchor, arrow, tid in (
            (SAFE_MM, SAFE_MM, "start", "&#8598;", 0),            # up-left
            (pw - SAFE_MM, SAFE_MM, "end", "&#8599;", 1),         # up-right
            (pw - SAFE_MM, ph - SAFE_MM, "end", "&#8600;", 2),    # down-right
            (SAFE_MM, ph - SAFE_MM, "start", "&#8601;", 3)):      # down-left
        label = f"{arrow} tag {tid}" if anchor == "start" else f"tag {tid} {arrow}"
        s.append(f'<text x="{tx:.4f}" y="{ty:.4f}" text-anchor="{anchor}">{label}</text>')
    s.append("</g>")

    # Print check. Everything here stays SAFE_MM inside the page: most printers cannot mark
    # the outer few millimetres, and annotations placed nearer than that get clipped, which
    # looks exactly like the drawing being the wrong size.
    bx, by = ox, ph - SAFE_MM - 2.0
    s.append(f'<g stroke="#000" stroke-width="0.4">'
             f'<line x1="{bx:.4f}" y1="{by:.4f}" x2="{bx + SCALE_BAR_MM:.4f}" y2="{by:.4f}"/>'
             f'<line x1="{bx:.4f}" y1="{by - 1.6:.4f}" x2="{bx:.4f}" y2="{by + 1.6:.4f}"/>'
             f'<line x1="{bx + SCALE_BAR_MM:.4f}" y1="{by - 1.6:.4f}" '
             f'x2="{bx + SCALE_BAR_MM:.4f}" y2="{by + 1.6:.4f}"/></g>'
             f'<text x="{bx + SCALE_BAR_MM + 3:.4f}" y="{by + 1.4:.4f}" '
             f'font-family="Helvetica,Arial,sans-serif" font-size="3.2">'
             f'this bar must measure {SCALE_BAR_MM} mm &#183; {rows}x{cols} grid of {cell} mm '
             f'cells &#183; grid origin ({ox:.2f}, {oy:.2f}) mm</text>')
    s.append("</svg>")
    return "\n".join(s), (ox, oy)


PRINT_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<style>
  /* This is the whole point of the wrapper. Printing an .svg straight from a browser uses
     whatever paper and orientation the dialog happens to default to, so a landscape drawing
     lands on portrait paper and is clipped or rescaled. Declaring the page size here makes
     the browser pick the right orientation and print at true size. */
  @page {{ size: {w}mm {h}mm; margin: 0; }}
  html, body {{ margin: 0; padding: 0; background: #fff; }}
  svg {{ display: block; width: {w}mm; height: {h}mm; }}
  @media screen {{
    body {{ background: #555; padding: 16px; font: 13px system-ui, sans-serif; color: #fff; }}
    svg {{ background: #fff; box-shadow: 0 2px 18px #0008; }}
    p {{ max-width: {w}mm; margin: 0 0 12px; }}
    b {{ color: #ffd866; }}
  }}
  @media print {{ .note {{ display: none; }} }}
</style></head><body>
<p class="note">Ctrl+P, then <b>Scale 100%</b> (or Default) and <b>Margins: None</b>.
Paper should already read {paper}. Measure the scale bar afterwards: it must be exactly
{bar} mm.</p>
{svg}
</body></html>
"""


def mat_tags_svg(pw, ph, sheet_w, sheet_h, tag_mm, gap):
    """The four tags to cut out and tape to the mat, each with its placement note."""
    pitch = max(tag_mm + 34.0, 62.0)
    pad = 8.0                      # white margin inside each cut square
    x0 = SAFE_MM + pad             # so the dashed cut line itself clears the printer margin
    y0 = 34.0
    usable = pw - 2 * SAFE_MM - (tag_mm + 2 * pad)
    cols = max(1, int(usable // pitch) + 1)
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{pw}mm" height="{ph}mm" '
         f'viewBox="0 0 {pw} {ph}">',
         '<rect width="100%" height="100%" fill="#fff"/>',
         '<g font-family="Helvetica,Arial,sans-serif" font-size="4" fill="#000">'
         f'<text x="{SAFE_MM}" y="14">Mat tags &#8212; cut on the dashed lines, tape to the mat.</text>'
         f'<text x="{SAFE_MM}" y="19" font-size="3.4" fill="#444">Each tag\'s inner corner (marked) '
         f'butts against a corner of the grid sheet, so nothing needs measuring. Do not rotate '
         f'them: keep every tag upright as printed.</text>'
         f'<text x="{SAFE_MM}" y="24" font-size="3.4" fill="#444">Tape the tags down first, then lay '
         f'the sheet inside them. Check the scale bar before cutting.</text></g>']

    corner_name = {0: "top-left", 1: "top-right", 2: "bottom-right", 3: "bottom-left"}
    inner = {0: (1, 1), 1: (-1, 1), 2: (-1, -1), 3: (1, -1)}

    for i, tid in enumerate((0, 1, 2, 3)):
        cx = x0 + (i % cols) * pitch
        cy = y0 + (i // cols) * pitch
        s.append(f'<rect x="{cx - pad:.4f}" y="{cy - pad:.4f}" '
                 f'width="{tag_mm + 2 * pad:.4f}" height="{tag_mm + 2 * pad:.4f}" '
                 f'fill="none" stroke="#bbb" stroke-width="0.25" stroke-dasharray="2 2"/>')
        s.append(tag_svg(tid, cx, cy, tag_mm))

        # Mark which corner of this tag meets the sheet, and draw the sheet's edge direction.
        sx, sy = inner[tid]
        ix = cx + (tag_mm if sx < 0 else 0)
        iy = cy + (tag_mm if sy < 0 else 0)
        s.append(f'<g stroke="#d00" fill="none" stroke-width="0.4">'
                 f'<path d="M {ix - sx * 5:.4f} {iy:.4f} L {ix:.4f} {iy:.4f} '
                 f'L {ix:.4f} {iy - sy * 5:.4f}"/></g>')
        s.append(f'<circle cx="{ix:.4f}" cy="{iy:.4f}" r="0.9" fill="#d00"/>')
        s.append(f'<g font-family="Helvetica,Arial,sans-serif" font-size="3.4" fill="#000">'
                 f'<text x="{cx:.4f}" y="{cy - pad - 2.5:.4f}">tag {tid} &#8212; '
                 f'{corner_name[tid]}</text></g>')
        s.append(f'<g font-family="Helvetica,Arial,sans-serif" font-size="2.8" fill="#d00">'
                 f'<text x="{cx:.4f}" y="{cy + tag_mm + pad + 4:.4f}">'
                 f'&#9679; this corner touches the sheet\'s {corner_name[tid]} corner</text></g>')

    by = min(y0 + ((4 - 1) // cols + 1) * pitch + 6, ph - SAFE_MM - 2.0)
    bx = SAFE_MM
    s.append(f'<g stroke="#000" stroke-width="0.4">'
             f'<line x1="{bx}" y1="{by:.4f}" x2="{bx + SCALE_BAR_MM:.4f}" y2="{by:.4f}"/>'
             f'<line x1="{bx}" y1="{by - 1.6:.4f}" x2="{bx}" y2="{by + 1.6:.4f}"/>'
             f'<line x1="{bx + SCALE_BAR_MM:.4f}" y1="{by - 1.6:.4f}" '
             f'x2="{bx + SCALE_BAR_MM:.4f}" y2="{by + 1.6:.4f}"/></g>'
             f'<text x="{bx + SCALE_BAR_MM + 3:.4f}" y="{by + 1.5:.4f}" '
             f'font-family="Helvetica,Arial,sans-serif" font-size="3.4">'
             f'must measure {SCALE_BAR_MM} mm, and each tag {tag_mm} mm across</text>')
    s.append("</svg>")
    return "\n".join(s)


def spec(sheet_w, sheet_h, rows, cols, cell, origin, tag_mm, gap):
    """The spec JSON the whole robot module reads.

    The sheet frame is unchanged in character: origin at the sheet's top-left corner, x right,
    y down the page, mm. What changes is that the tags now sit at *negative* coordinates and
    beyond the sheet's width and height, because they are on the mat outside the paper.
    """
    ox, oy = origin
    # Each tag's inner corner meets a sheet corner, `gap` mm diagonally outside it.
    boxes = {
        0: (-gap - tag_mm, -gap - tag_mm),
        1: (sheet_w + gap, -gap - tag_mm),
        2: (sheet_w + gap, sheet_h + gap),
        3: (-gap - tag_mm, sheet_h + gap),
    }
    tags = {}
    for tid, (x0, y0) in boxes.items():
        x1, y1 = x0 + tag_mm, y0 + tag_mm
        tags[str(tid)] = {
            "center_mm": [round(x0 + tag_mm / 2, 4), round(y0 + tag_mm / 2, 4)],
            # TL, TR, BR, BL, matching cv2.aruco.detectMarkers' corner order.
            "corners_mm": [[round(x0, 4), round(y0, 4)], [round(x1, 4), round(y0, 4)],
                           [round(x1, 4), round(y1, 4)], [round(x0, 4), round(y1, 4)]],
        }
    return {
        "source": f"robot/scripts/make_sheet.py: {rows}x{cols} grid, tags on the mat",
        "generated": time.strftime("%Y-%m-%d %H:%M"),
        "frame": "sheet: origin at the grid sheet's top-left corner, x right (tag0->tag1), "
                 "y down the page (tag0->tag3), mm. Tags sit on the mat outside the paper, so "
                 "their coordinates are negative or past the sheet's width and height.",
        "sheet": {"w_mm": sheet_w, "h_mm": sheet_h},
        "dictionary": DICTIONARY,
        "tag_size_mm": tag_mm,
        "tag_gap_mm": gap,
        "tags": tags,
        "grid": {
            "origin_mm": [round(ox, 4), round(oy, 4)],
            "cell_mm": cell,
            "rows": list(ROW_LETTERS[:rows]),
            "cols": list(range(1, cols + 1)),
            "naming": "letter is the row (A nearest the arm), number is the column",
        },
        "print_check": f"the scale bar must measure {SCALE_BAR_MM} mm (2.00 in)",
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rows", type=int, default=3)
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--cell", type=float, default=CELL_MM)
    ap.add_argument("--paper", default="letter", choices=sorted(PAPERS))
    ap.add_argument("--portrait", action="store_true",
                    help="keep the paper portrait (the default turns it landscape, which is "
                         "what fits the wider grid)")
    ap.add_argument("--tag-mm", type=float, default=TAG_MM)
    ap.add_argument("--gap", type=float, default=0.0,
                    help="mm between each tag's inner corner and the sheet corner. 0 means "
                         "they touch, so the sheet aligns the tags with nothing to measure.")
    ap.add_argument("--no-spec", action="store_true", help="write the printables only")
    ap.add_argument("--out", default=str(ASSETS))
    args = ap.parse_args()

    pw, ph = PAPERS[args.paper]
    if not args.portrait:
        pw, ph = ph, pw

    gw, gh = args.cols * args.cell, args.rows * args.cell
    if gw > pw or gh > ph:
        fits_c, fits_r = int(pw // args.cell), int(ph // args.cell)
        raise SystemExit(
            f"a {args.rows}x{args.cols} grid of {args.cell} mm cells needs "
            f"{gw:.1f} x {gh:.1f} mm, but the page is {pw} x {ph} mm.\n"
            f"That page fits at most {fits_r} rows x {fits_c} cols. Try "
            f"--rows {fits_r} --cols {fits_c}, or a bigger --paper.")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    grid_svg, origin = grid_sheet_svg(pw, ph, args.rows, args.cols, args.cell,
                                      args.gap, args.tag_mm)
    tags_svg = mat_tags_svg(*PAPERS["letter"], pw, ph, args.tag_mm, args.gap)

    grid_path = out / f"grid_sheet_{args.rows}x{args.cols}.svg"
    tags_path = out / "mat_tags.svg"
    grid_path.write_text(grid_svg, encoding="utf-8")
    tags_path.write_text(tags_svg, encoding="utf-8")

    # Print these, not the bare SVGs: the wrapper pins the paper size and orientation.
    tw, th = PAPERS["letter"]
    pages = [
        (grid_path.with_suffix(".print.html"), grid_svg, pw, ph,
         f"grid sheet {args.rows}x{args.cols}",
         f"{pw:.1f} x {ph:.1f} mm ({'landscape' if pw > ph else 'portrait'} Letter)"),
        (tags_path.with_suffix(".print.html"), tags_svg, tw, th,
         "mat tags", f"{tw:.1f} x {th:.1f} mm (portrait Letter)"),
    ]
    for path, svg, w, h, title, paper in pages:
        path.write_text(PRINT_HTML.format(title=title, w=w, h=h, paper=paper,
                                          bar=SCALE_BAR_MM, svg=svg), encoding="utf-8")

    print(f"page            {pw} x {ph} mm ({args.paper}"
          f"{' portrait' if args.portrait else ' landscape'})")
    print(f"grid            {args.rows} rows x {args.cols} cols = "
          f"{args.rows * args.cols} cells, {args.cell} mm each")
    print(f"grid extent     {gw:.1f} x {gh:.1f} mm, margins "
          f"{origin[0]:.1f} / {origin[1]:.1f} mm")
    print(f"tags            {args.tag_mm} mm, on the mat, {args.gap:g} mm outside the corners")
    print(f"wrote           {grid_path}")
    print(f"wrote           {tags_path}")
    for path, *_ in pages:
        print(f"wrote           {path}   <- PRINT THIS ONE")

    if not args.no_spec:
        spec_path = out / "workspace_sheet.json"
        if spec_path.exists():
            backup = out.parent / "outputs" / (
                f"workspace_sheet_before_{time.strftime('%Y%m%d_%H%M%S')}.json")
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(spec_path, backup)
            print(f"backed up       {backup}")
        spec_path.write_text(
            json.dumps(spec(pw, ph, args.rows, args.cols, args.cell, origin,
                            args.tag_mm, args.gap), indent=2) + "\n", encoding="utf-8")
        print(f"wrote           {spec_path}")

    print()
    print("Next, in order:")
    print("  1. Open the two .print.html files in a browser and print them at 100%.")
    print("     They pin the paper size, so a landscape sheet cannot land on portrait")
    print("     paper and get clipped. Then measure the scale bars with a ruler.")
    print("  2. Tape the four tags to the mat, inner corners against the sheet's corners.")
    print("  3. Tape the grid sheet down inside them.")
    print("  4. python -m robot.scripts.tests.scene_snapshot        # all 4 tags seen?")
    print("  5. python -m robot.scripts.calibration.touch_calibrate --full")
    print("  6. python -m robot.scripts.calibration.auto_calibrate")


if __name__ == "__main__":
    main()
