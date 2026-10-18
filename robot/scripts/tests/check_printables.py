"""Rasterise the generated SVGs and run the tags back through the detector.

    python -m robot.scripts.tests.check_printables

Catches the failure that would otherwise only show up after printing and taping: a tag that
decodes to the wrong id, or not at all, because of a bit-order or orientation slip in the
generator. Rasterising the SVG's own rectangles tests the file that gets printed rather than
the intent behind it.

A deliberately crude rasteriser: these SVGs are nothing but axis-aligned <rect>s, so filling
boxes into an array reproduces them exactly. It does not understand paths, text or strokes,
and does not need to.
"""

import re
import sys
from pathlib import Path

import cv2
import numpy as np

from robot.perception.config import ROOT

RECT = re.compile(
    r'<rect\s+x="(-?[\d.]+)"\s+y="(-?[\d.]+)"\s+'
    r'width="([\d.]+)"\s+height="([\d.]+)"\s+fill="(#[0-9a-fA-F]{3,6})"')
PX_PER_MM = 8.0            # ~200 dpi, well above what the detector needs


def rasterise(svg_text, px_per_mm=PX_PER_MM):
    head = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg_text)
    w_mm, h_mm = float(head.group(1)), float(head.group(2))
    w, h = int(w_mm * px_per_mm), int(h_mm * px_per_mm)
    img = np.full((h, w), 255, np.uint8)
    for x, y, rw, rh, fill in RECT.findall(svg_text):
        x0 = int(round(float(x) * px_per_mm))
        y0 = int(round(float(y) * px_per_mm))
        x1 = int(round((float(x) + float(rw)) * px_per_mm))
        y1 = int(round((float(y) + float(rh)) * px_per_mm))
        val = 0 if fill.lower() in ("#000", "#000000") else 255
        if fill.lower() not in ("#000", "#000000", "#fff", "#ffffff"):
            continue           # a coloured guide mark, not part of a tag
        x0, y0 = max(x0, 0), max(y0, 0)
        if x1 > x0 and y1 > y0:
            img[y0:y1, x0:x1] = val
    return img, (w_mm, h_mm)


def main():
    assets = ROOT / "assets"
    spec_path = assets / "workspace_sheet.json"
    ok = True

    tags_svg = assets / "mat_tags.svg"
    if not tags_svg.exists():
        raise SystemExit(f"{tags_svg} is missing: run python -m robot.scripts.make_sheet first")

    img, (w_mm, h_mm) = rasterise(tags_svg.read_text(encoding="utf-8"))
    print(f"mat_tags.svg       {w_mm:.1f} x {h_mm:.1f} mm -> "
          f"{img.shape[1]} x {img.shape[0]} px at {PX_PER_MM:g} px/mm")

    import json
    dictionary = "DICT_APRILTAG_36h11"
    if spec_path.exists():
        dictionary = json.loads(spec_path.read_text()).get("dictionary", dictionary)
    d = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, dictionary))
    detector = cv2.aruco.ArucoDetector(d, cv2.aruco.DetectorParameters())
    corners, ids, _ = detector.detectMarkers(img)

    found = sorted(int(i) for i in ids.flatten()) if ids is not None else []
    print(f"  dictionary       {dictionary}")
    print(f"  tags decoded     {found}")
    if found != [0, 1, 2, 3]:
        print("  FAIL: expected [0, 1, 2, 3]")
        ok = False
    else:
        print("  PASS: all four tags decode to the right ids")

    # Each tag must also come out the right size and square, or the homography inherits the error.
    if ids is not None:
        for c, i in zip(corners, ids.flatten()):
            p = c.reshape(4, 2)
            sides = [np.linalg.norm(p[(k + 1) % 4] - p[k]) / PX_PER_MM for k in range(4)]
            spread = max(sides) - min(sides)
            print(f"  tag {int(i)}            sides {' '.join(f'{s:.2f}' for s in sides)} mm"
                  f"   (max-min {spread:.3f} mm)")
            if spread > 0.3:
                print(f"  FAIL: tag {int(i)} is not square")
                ok = False

    grid = next(iter(sorted(assets.glob("grid_sheet_*.svg"))), None)
    if grid:
        img2, (gw, gh) = rasterise(grid.read_text(encoding="utf-8"))
        corners2, ids2, _ = detector.detectMarkers(img2)
        n = 0 if ids2 is None else len(ids2)
        print(f"\n{grid.name}  {gw:.1f} x {gh:.1f} mm")
        print(f"  tags on sheet    {n}")
        if n:
            print("  FAIL: the grid sheet should carry no tags; they belong on the mat")
            ok = False
        else:
            print("  PASS: no tags on the grid sheet, as intended")

    if spec_path.exists():
        spec = json.loads(spec_path.read_text())
        print(f"\nworkspace_sheet.json")
        print(f"  sheet            {spec.get('sheet')}")
        print(f"  grid             {spec['grid']['rows']} x {spec['grid']['cols']}, "
              f"cell {spec['grid']['cell_mm']} mm, origin {spec['grid']['origin_mm']}")
        tag_ids = sorted(int(k) for k in spec["tags"])
        print(f"  tags in spec     {tag_ids}")
        if tag_ids != [0, 1, 2, 3]:
            print("  FAIL: spec must describe tags 0-3")
            ok = False
        # Every tag must be outside the paper now.
        if "sheet" not in spec:
            print("  stale spec: no 'sheet' size. Re-run make_sheet without --no-spec.")
            ok = False
        else:
            sw, sh = spec["sheet"]["w_mm"], spec["sheet"]["h_mm"]
            on_paper = []
            for tid, t in spec["tags"].items():
                xs = [p[0] for p in t["corners_mm"]]
                ys = [p[1] for p in t["corners_mm"]]
                if min(xs) > 0 and max(xs) < sw and min(ys) > 0 and max(ys) < sh:
                    on_paper.append(tid)
            if on_paper:
                print(f"  FAIL: tags {on_paper} lie on the paper, not the mat")
                ok = False
            else:
                print("  PASS: every tag sits off the paper, on the mat")

    print("\n" + ("all checks passed" if ok else "SOMETHING IS WRONG - do not print yet"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
