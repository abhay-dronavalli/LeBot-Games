"""Read the real board a few times and say what the model saw. Use it to check accuracy.

    ./run stop                                   # the bridge holds the camera
    python -m robot.scripts.tests.board_check
    python -m robot.scripts.tests.board_check --expect A4=purple
    python -m robot.scripts.tests.board_check --model gpt-4o --model gpt-5.1 -n 3

Why it exists. A misread board looks like a calibration problem from inside Roblox: the colour
is usually right and the *cell* is wrong, so blocks appear in the wrong square and nothing
says why. This asks the question directly, several times, so a wrong answer can be told from
an unstable one - and with `--model` twice it compares two models on the same frame, which is
how gpt-5.1 was chosen over gpt-4o (gpt-4o read a cube in A4 as B4, three times out of three).

Re-run it after moving the rig, re-tuning the camera, or changing the model. `--save` writes
the frame it used, which is worth keeping when an answer looks wrong.
"""

import argparse
import sys
import time
from collections import Counter

from bridge import board as board_mod
from robot.perception.camera import Camera


def describe(readings):
    if not readings:
        return "(nothing on the board)"
    return ", ".join(f"{r['cell']}={r['color']}" + (f"(L{r['level']})" if r["level"] else "")
                     for r in sorted(readings, key=lambda r: r["cell"]))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--model", action="append", default=None,
                    help="model to try; repeat to compare several on the same frame")
    ap.add_argument("-n", "--trials", type=int, default=3,
                    help="reads per model (default 3): one answer cannot show instability")
    ap.add_argument("--expect", default=None,
                    help='the right answer, e.g. "A4=purple" or "A4=purple,C1=red"')
    ap.add_argument("--save", metavar="PATH", default=None, help="write the frame used")
    args = ap.parse_args(argv)

    if not board_mod.available():
        raise SystemExit("no OPENAI_API_KEY (environment, or a .env at the repo root)")

    models = args.model or [board_mod.model_name()]
    want = None
    if args.expect:
        want = describe([{"cell": c.strip().upper(), "color": v.strip().lower(), "level": 0}
                         for c, _, v in (p.partition("=") for p in args.expect.split(","))])

    try:
        with Camera() as cam:
            print(f"camera settings applied: {cam.applied or '(none saved - run ./run camera)'}")
            frame = cam.read()
    except RuntimeError as e:
        raise SystemExit(f"{e}\nIs the bridge running with --vision? Stop it first: ./run stop")

    if args.save:
        import cv2
        cv2.imwrite(args.save, frame)
        print(f"frame saved to {args.save}")
    if want:
        print(f"expected: {want}")
    print()

    worst = 0
    for model in models:
        answers = Counter()
        for i in range(args.trials):
            t0 = time.perf_counter()
            try:
                got = describe(board_mod.read_board(frame, model=model))
            except Exception as e:                      # noqa: BLE001 - report, don't crash
                got = f"FAILED {type(e).__name__}: {e}"
            answers[got] += 1
            mark = "" if want is None else ("  ok" if got == want else "  <- wrong")
            print(f"  {model:<10} #{i + 1}  {time.perf_counter() - t0:5.1f}s  {got}{mark}")
            g = getattr(board_mod.read_board, "last", {}).get("geometry")
            if g:
                what = (f"-> cells {g['cells']}" if g.get("cells") is not None
                        else "-> cropped and labelled; the model decided the rest")
                if g.get("invented") or g.get("skipped"):
                    what += f", model invented {g['invented']} skipped {g['skipped']}"
                print(f"             sheet[{g.get('mode')}]: tags {g['tags']} "
                      f"fit {g['fit_mm']}mm {what}")
            elif g is None and i == 0:
                print(f"             sheet: not used (BOARD_VISION={board_mod.vision_mode()})"
                      " - the model is reading an uncropped frame")

        top, hits = answers.most_common(1)[0]
        if len(answers) > 1:
            print(f"  {model:<10} UNSTABLE: {len(answers)} different answers in {args.trials} reads")
            worst = max(worst, 2)
        elif want is not None and top != want:
            print(f"  {model:<10} consistently wrong ({hits}/{args.trials})")
            worst = max(worst, 1)
        print()

    if want is None:
        print("No --expect given, so this only shows stability, not correctness.")
    return worst


if __name__ == "__main__":
    sys.exit(main())
