"""Tune the overhead camera until every block colour is unmistakable, then save the settings.

    ~/lerobot/.venv/Scripts/python.exe -m robot.scripts.tools.camera_tune

Why this exists. Left on auto, the camera meters for the white sheet that fills most of the
frame. The cubes sitting on it come out under-exposed and desaturated, white balance wanders
as the arm's shadow moves, and two pairs collapse into each other: orange reads as yellow,
teal reads as light blue. The vision model is then being asked to split colours that are not
actually different in the picture, and no prompt wording fixes a photo.

So: a live view with the camera's own exposure and white-balance controls, and a number that
says whether the colours have actually separated.

**The number is the point.** Eyeballing "are these different enough" is exactly the judgement
that got us here. Click each cube once and this samples its colour in CIE Lab, where distance
matches human perception, then reports the *closest pair* - because the board is only as
readable as its worst pair. Turn the knobs until that number stops going up.

    dE < 10   the pair is a coin flip. The model will mix them up, and so will you.
    10 - 20   distinguishable side by side, unreliable alone.
    20 - 35   comfortable. This is the target.
    > 35      plenty.

Keys:
    click     sample the cube under the cursor (up to one per kit colour, in palette order)
    u         undo the last sample          c  clear all samples
    r         re-sample every point from the current frame, after changing a setting
    a         toggle auto-exposure          w  toggle auto white balance
    s         save to robot/calibration/camera_settings.json
    d         restore this rig's defaults (delete nothing; just resets the sliders)
    q / Esc   quit without saving

The sliders are raw driver values, not physical units - a webcam exposes whatever it feels
like, and DirectShow exposure is usually a negative log2 scale (-1 is bright, -11 is dark).
Anything the driver refuses is shown as "not supported" rather than silently ignored.
"""

import sys

import cv2
import numpy as np

from robot.perception.camera import (
    SETTING_ORDER, SETTING_PROPS, apply_settings, load_settings, save_settings, SETTINGS_PATH,
)
from robot.perception.config import BLOCK_COLORS, CAMERA_INDEX, FRAME_H, FRAME_W

WINDOW = "camera tune"
PANEL = "settings"
SAMPLE_PATCH = 9          # odd: a (2n+1) square around the click, median-filtered
SWATCH_H = 110
GOOD_DE = 20.0            # the separation worth stopping at

# Slider ranges. DirectShow reports nonsense minima for most of these, so they are hard-coded
# to the useful part of each range rather than queried.
SLIDERS = [
    ("exposure", -13, 1, -6),
    ("gain", 0, 255, 0),
    ("white_balance", 2000, 9000, 4600),
    ("brightness", 0, 255, 128),
    ("contrast", 0, 255, 128),
    ("saturation", 0, 255, 160),
]
DEFAULTS = {name: default for name, _, _, default in SLIDERS}
DEFAULTS.update({"auto_exposure": 0.25, "auto_wb": 0.0})   # 0.25 = manual on most DirectShow cams


def lab_of(bgr_patch):
    """The patch's colour in CIE Lab, median over the patch so one glare pixel cannot move it."""
    lab = cv2.cvtColor(bgr_patch, cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(np.float32)
    med = np.median(lab, axis=0)
    # OpenCV packs 8-bit Lab as L*255/100, a+128, b+128. Undo that so dE is in real Lab units.
    return np.array([med[0] * 100.0 / 255.0, med[1] - 128.0, med[2] - 128.0], dtype=np.float32)


def worst_pair(samples):
    """The closest two samples and their distance: the board is as good as its worst pair."""
    if len(samples) < 2:
        return None, None, None
    best = None
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            d = float(np.linalg.norm(samples[i]["lab"] - samples[j]["lab"]))
            if best is None or d < best[2]:
                best = (i, j, d)
    return best


def draw_swatches(width, samples):
    """A strip of what was sampled, each chip labelled with its distance to its nearest other
    colour - so the pair that needs work names itself."""
    strip = np.full((SWATCH_H, width, 3), 24, dtype=np.uint8)
    if not samples:
        cv2.putText(strip, "click each cube once to sample it", (12, 60),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 200), 1, cv2.LINE_AA)
        return strip
    w = max(90, min(190, width // max(len(samples), 1)))
    for k, s in enumerate(samples):
        x0 = k * w
        if x0 + w > width:
            break
        cv2.rectangle(strip, (x0 + 4, 8), (x0 + w - 6, 62), [int(v) for v in s["bgr"]], -1)
        cv2.rectangle(strip, (x0 + 4, 8), (x0 + w - 6, 62), (90, 90, 90), 1)
        near = min((float(np.linalg.norm(s["lab"] - o["lab"]))
                    for o in samples if o is not s), default=None)
        cv2.putText(strip, s["name"][:12], (x0 + 8, 78),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.42, (230, 230, 230), 1, cv2.LINE_AA)
        if near is not None:
            colour = (90, 230, 120) if near >= GOOD_DE else (90, 160, 255)
            cv2.putText(strip, f"dE {near:.0f}", (x0 + 8, 98),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.46, colour, 1, cv2.LINE_AA)
    return strip


def main():
    cap = cv2.VideoCapture(CAMERA_INDEX, cv2.CAP_DSHOW)
    if not cap.isOpened():
        raise SystemExit(f"Can't open camera {CAMERA_INDEX}. Close the Camera app and retry.")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_H)

    settings = dict(DEFAULTS)
    settings.update(load_settings())
    applied = apply_settings(cap, settings)
    refused = [k for k in settings if k not in applied]

    print(f"camera {CAMERA_INDEX}: {len(applied)} setting(s) accepted"
          + (f", not supported: {', '.join(sorted(refused))}" if refused else ""))
    print(f"settings file: {SETTINGS_PATH}")
    print(__doc__.split("Keys:")[1].split("The sliders")[0].rstrip())

    cv2.namedWindow(WINDOW, cv2.WINDOW_NORMAL)
    cv2.namedWindow(PANEL, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(PANEL, 520, 300)

    # Trackbars cannot go negative, so each one is stored shifted by its minimum.
    for name, lo, hi, _ in SLIDERS:
        cv2.createTrackbar(name, PANEL, int(settings.get(name, DEFAULTS[name])) - lo, hi - lo,
                           lambda _v: None)

    samples = []
    frame_holder = {"frame": None}

    def on_mouse(event, x, y, _flags, _param):
        if event != cv2.EVENT_LBUTTONDOWN:
            return
        frame = frame_holder["frame"]
        if frame is None or len(samples) >= len(BLOCK_COLORS):
            return
        h, w = frame.shape[:2]
        r = SAMPLE_PATCH // 2
        x0, x1 = max(0, x - r), min(w, x + r + 1)
        y0, y1 = max(0, y - r), min(h, y + r + 1)
        patch = frame[y0:y1, x0:x1]
        if patch.size == 0:
            return
        samples.append({
            "name": BLOCK_COLORS[len(samples)],
            "xy": (x, y),
            "lab": lab_of(patch),
            "bgr": np.median(patch.reshape(-1, 3), axis=0),
        })
        print(f"  sampled {samples[-1]['name']:<11} at ({x},{y})")

    cv2.setMouseCallback(WINDOW, on_mouse)

    def resample():
        frame = frame_holder["frame"]
        if frame is None:
            return
        h, w = frame.shape[:2]
        r = SAMPLE_PATCH // 2
        for s in samples:
            x, y = s["xy"]
            patch = frame[max(0, y - r):min(h, y + r + 1), max(0, x - r):min(w, x + r + 1)]
            if patch.size:
                s["lab"] = lab_of(patch)
                s["bgr"] = np.median(patch.reshape(-1, 3), axis=0)

    while True:
        ok, frame = cap.read()
        if not ok:
            continue
        frame_holder["frame"] = frame

        # Push any slider the user moved.
        changed = False
        for name, lo, hi, _ in SLIDERS:
            try:
                v = cv2.getTrackbarPos(name, PANEL) + lo
            except cv2.error:
                return  # panel closed
            if settings.get(name) != v:
                settings[name] = v
                cap.set(SETTING_PROPS[name], float(v))
                changed = True
        if changed:
            resample()

        view = frame.copy()
        for s in samples:
            cv2.circle(view, s["xy"], 11, (255, 255, 255), 2)
            cv2.circle(view, s["xy"], 12, (0, 0, 0), 1)
            cv2.putText(view, s["name"][:10], (s["xy"][0] + 15, s["xy"][1] + 4),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 2, cv2.LINE_AA)

        i, j, d = worst_pair(samples)
        if d is None:
            head = f"sampled {len(samples)}/{len(BLOCK_COLORS)} - click each cube once"
            colour = (200, 200, 200)
        else:
            head = f"worst pair: {samples[i]['name']} vs {samples[j]['name']}   dE {d:.1f}"
            colour = (90, 230, 120) if d >= GOOD_DE else (80, 160, 255)
        cv2.rectangle(view, (0, 0), (view.shape[1], 40), (18, 18, 18), -1)
        cv2.putText(view, head, (12, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, colour, 2, cv2.LINE_AA)
        auto = f"auto-exp {'ON' if settings.get('auto_exposure', 0) >= 0.5 else 'off'}  " \
               f"auto-wb {'ON' if settings.get('auto_wb', 0) >= 0.5 else 'off'}   [a] [w]  [s]ave  [q]uit"
        cv2.putText(view, auto, (12, view.shape[0] - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (210, 210, 210), 1, cv2.LINE_AA)

        cv2.imshow(WINDOW, np.vstack([view, draw_swatches(view.shape[1], samples)]))

        key = cv2.waitKey(1) & 0xFF
        if key in (ord("q"), 27):
            print("quit without saving")
            break
        if key == ord("s"):
            kept = save_settings(settings)
            print(f"saved {len(kept)} setting(s) to {SETTINGS_PATH}")
            if d is not None and d < GOOD_DE:
                print(f"  note: worst pair is still dE {d:.1f} "
                      f"({samples[i]['name']} vs {samples[j]['name']}) - under {GOOD_DE:.0f} "
                      f"the model will still mix them up")
            break
        if key == ord("u") and samples:
            print(f"  removed {samples.pop()['name']}")
        elif key == ord("c"):
            samples.clear()
        elif key == ord("r"):
            resample()
        elif key == ord("a"):
            settings["auto_exposure"] = 0.75 if settings.get("auto_exposure", 0) < 0.5 else 0.25
            cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, settings["auto_exposure"])
        elif key == ord("w"):
            settings["auto_wb"] = 1.0 if settings.get("auto_wb", 0) < 0.5 else 0.0
            cap.set(cv2.CAP_PROP_AUTO_WB, settings["auto_wb"])
        elif key == ord("d"):
            settings.update(DEFAULTS)
            for name, lo, _hi, default in SLIDERS:
                cv2.setTrackbarPos(name, PANEL, default - lo)
            apply_settings(cap, settings)
            resample()

    cap.release()
    cv2.destroyAllWindows()
    return 0


if __name__ == "__main__":
    sys.exit(main())
