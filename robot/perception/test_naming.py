"""ColorNamer on a synthetic frame, no camera and no vision model.

    python -m robot.perception.test_naming
"""

import tempfile
from pathlib import Path

import numpy as np

from robot.perception import color
from robot.perception.naming import ColorNamer

RED, TEAL, PAPER = (60, 56, 226), (155, 165, 22), (235, 238, 240)   # BGR


def square(x, y, size=80):
    return np.array([[x, y], [x + size, y], [x + size, y + size], [x, y + size]], np.int32)


def frame_with(blocks):
    img = np.full((400, 800, 3), PAPER, np.uint8)
    for (x, y), bgr in blocks:
        img[y:y + 80, x:x + 80] = bgr
    return img


def check(label, got, want):
    ok = got == want
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    if not ok:
        print(f"        got  {got}")
        print(f"        want {want}")
    return ok


def namer_for(img, samples):
    """A namer whose memory learned each colour from one square of `img` (a fresh temp file, so
    the rig's committed colour memory is never read or written)."""
    memory = color.ColorMemory(path=Path(tempfile.mkdtemp()) / "color_memory.json")
    for name, contour in samples:
        memory.learn(name, color.signature(img, contour))
    return ColorNamer(memory=memory, use_model=False, log=lambda m: None)


def scenario_two_reds_keep_their_name():
    """The rig has more than one cube of a colour. Two cubes both confidently red are both
    named red; they used to be forced apart, so the second one read as orange or purple."""
    print("naming: two red cubes and a teal one")
    spots = [((60, 100), RED), ((300, 100), RED), ((540, 100), TEAL)]
    img = frame_with(spots)
    contours = [square(x, y) for (x, y), _ in spots]
    namer = namer_for(img, [("red", contours[0]), ("teal", contours[2])])
    names = namer.name(img, contours)
    ok = check("both reds stay red", names, ["red", "red", "teal"])
    ok &= check("named from memory, no guessing", namer.last_source, "memory")
    return ok


def main():
    results = [scenario_two_reds_keep_their_name()]
    print(f"\n{sum(1 for r in results if r)}/{len(results)} scenarios passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
