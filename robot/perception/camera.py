"""Overhead camera capture (OpenCV, DirectShow on Windows).

A background thread keeps reading so read() always returns the newest frame. Without it,
DirectShow can hand back frames buffered seconds ago when the camera sat idle (e.g. while
the arm was moving), which showed the arm where it no longer was.

**Exposure and white balance are saved settings, not whatever the camera felt like.** Left on
auto, this camera meters for the white sheet that fills most of the frame, under-exposes the
cubes sitting on it, and drags white balance around as the arm's shadow moves. Orange and
yellow then land on the same washed-out tone, and so do teal and light blue - which the vision
model cannot read apart any better than a person can. `robot/scripts/tools/camera_tune.py`
writes the settings here; this module applies them on open. With no settings file, the camera
keeps its own auto behaviour, so nothing breaks on a rig that has not been tuned.
"""

import json
import threading
import time
from pathlib import Path

import cv2

from .config import CAMERA_INDEX, FRAME_H, FRAME_W, ROOT

SETTINGS_PATH = Path(ROOT) / "calibration" / "camera_settings.json"   # ROOT is robot/

# The properties the tuner writes and this module replays, in the order they must be set:
# the auto switches go first, because a driver ignores a manual exposure written while
# auto-exposure is still on.
SETTING_ORDER = [
    "auto_exposure", "auto_wb", "exposure", "gain", "white_balance",
    "brightness", "contrast", "saturation",
]
SETTING_PROPS = {
    "auto_exposure": cv2.CAP_PROP_AUTO_EXPOSURE,
    "auto_wb": cv2.CAP_PROP_AUTO_WB,
    "exposure": cv2.CAP_PROP_EXPOSURE,
    "gain": cv2.CAP_PROP_GAIN,
    "white_balance": cv2.CAP_PROP_WB_TEMPERATURE,
    "brightness": cv2.CAP_PROP_BRIGHTNESS,
    "contrast": cv2.CAP_PROP_CONTRAST,
    "saturation": cv2.CAP_PROP_SATURATION,
}


def load_settings(path=SETTINGS_PATH):
    """The saved camera settings, or {} when this rig has never been tuned."""
    try:
        with open(path, encoding="utf-8") as fh:
            saved = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in saved.items() if k in SETTING_PROPS and v is not None}


def save_settings(settings, path=SETTINGS_PATH):
    keep = {k: settings[k] for k in SETTING_ORDER if settings.get(k) is not None}
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(keep, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return keep


def apply_settings(cap, settings):
    """Write settings onto an open capture. Returns the ones the driver accepted - a webcam
    silently refuses properties it does not support, so the caller can say which took."""
    applied = {}
    for key in SETTING_ORDER:
        if settings.get(key) is None:
            continue
        if cap.set(SETTING_PROPS[key], float(settings[key])):
            applied[key] = settings[key]
        time.sleep(0.02)   # DirectShow needs a beat between property writes
    return applied


class Camera:
    def __init__(self, index=CAMERA_INDEX, width=FRAME_W, height=FRAME_H, warmup_s=1.5,
                 settings=None):
        self.cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
        if not self.cap.isOpened():
            raise RuntimeError(
                f"Can't open camera {index}. Close the Windows Camera app or anything else using it."
            )
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.settings = load_settings() if settings is None else dict(settings)
        self.applied = apply_settings(self.cap, self.settings) if self.settings else {}
        self._frame, self._stamp = None, 0.0
        self._lock = threading.Lock()
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        time.sleep(warmup_s)  # let auto-exposure settle

    def _loop(self):
        while self._running:
            ok, frame = self.cap.read()
            if ok:
                with self._lock:
                    self._frame, self._stamp = frame, time.time()

    def read(self, max_age_s=0.5, timeout_s=3.0):
        """Newest frame captured after this call started (and at most max_age_s old)."""
        asked = time.time()
        deadline = asked + timeout_s
        while time.time() < deadline:
            with self._lock:
                if self._frame is not None and self._stamp >= asked - max_age_s and self._stamp > asked:
                    return self._frame.copy()
            time.sleep(0.01)
        raise RuntimeError("Camera returned no fresh frame")

    def latest(self):
        """The most recent frame, without waiting (None before the first frame arrives)."""
        with self._lock:
            return None if self._frame is None else self._frame.copy()

    def close(self):
        self._running = False
        self._thread.join(timeout=2)
        self.cap.release()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
