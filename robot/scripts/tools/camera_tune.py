"""Tune the overhead camera until every block colour is unmistakable, then save the settings.

    ./run camera        (or: python -m robot.scripts.tools.camera_tune)

Opens http://localhost:8767 in a browser. **It is a web page, not an OpenCV window**: the venv
has `opencv-python-headless`, which is built with `GUI: NONE`, so `cv2.imshow` can never open
anything here. Swapping in the full build to get a window would mean changing a package
lerobot depends on, which is not worth breaking a working rig for - and a page also works from
a laptop across the room when the rig is somewhere awkward.

Why this exists. Left on auto, the camera meters for the white sheet that fills most of the
frame. The cubes come out under-exposed and desaturated, white balance wanders as the arm's
shadow moves, and two pairs collapse into each other: orange reads as yellow, teal reads as
light blue. The vision model is then being asked to split colours that are not actually
different in the picture, and no prompt wording fixes a photo.

**The number is the point.** Eyeballing "are these different enough" is exactly the judgement
that got us here. Click each cube once; the page samples it in CIE Lab, where distance matches
human perception, and reports the *closest pair* - the board is only as readable as its worst
pair. Turn the sliders until that number stops going up, then Save.

    dE < 10   the pair is a coin flip. The model will mix them up, and so will you.
    10 - 20   distinguishable side by side, unreliable alone.
    20 - 35   comfortable. This is the target.
    > 35      plenty.

Settings are written to robot/calibration/camera_settings.json, which robot.perception.camera
applies whenever it opens the camera. Re-run this after every move: the separation depends on
the room's light, so last location's numbers mean nothing here.
"""

import json
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import cv2
import numpy as np

from robot.perception.camera import (
    SETTING_PROPS, apply_settings, load_settings, save_settings, SETTINGS_PATH,
)
from robot.perception.config import BLOCK_COLORS, CAMERA_INDEX, FRAME_H, FRAME_W

PORT = 8767                # 8765 is the websocket, 8766 the bridge viewer
SAMPLE_PATCH = 9           # odd: a square around the click, median-filtered
GOOD_DE = 20.0             # the separation worth stopping at
JPEG_QUALITY = 80

# Slider ranges. DirectShow reports nonsense minima for most of these, so they are pinned to
# the useful part of each range rather than queried.
SLIDERS = [
    ("exposure", -13, 1, -6, "lower = darker. The main control: start here."),
    ("gain", 0, 255, 0, "raises brightness and noise together. Prefer exposure."),
    ("white_balance", 2000, 9000, 4600, "lower = cooler/bluer. Splits teal from light blue."),
    ("brightness", 0, 255, 128, ""),
    ("contrast", 0, 255, 128, ""),
    ("saturation", 0, 255, 160, "the one that splits orange from yellow."),
]
DEFAULTS = {name: default for name, _, _, default, _ in SLIDERS}
DEFAULTS.update({"auto_exposure": 0.25, "auto_wb": 0.0})  # 0.25 = manual on most DirectShow cams

state_lock = threading.Lock()
settings = {}
samples = []               # [{name, x, y, lab, rgb}]
cap = None
latest = {"frame": None}


# ---- colour maths ----------------------------------------------------------------

def lab_of(patch):
    """The patch's colour in CIE Lab, median over the patch so one glare pixel cannot move it."""
    lab = cv2.cvtColor(patch, cv2.COLOR_BGR2LAB).reshape(-1, 3).astype(np.float32)
    med = np.median(lab, axis=0)
    # OpenCV packs 8-bit Lab as L*255/100, a+128, b+128. Undo that so dE is in real Lab units.
    return [float(med[0] * 100.0 / 255.0), float(med[1] - 128.0), float(med[2] - 128.0)]


def worst_pair(items):
    """The closest two samples and their distance: the board is as good as its worst pair."""
    best = None
    for i in range(len(items)):
        for j in range(i + 1, len(items)):
            d = float(np.linalg.norm(np.array(items[i]["lab"]) - np.array(items[j]["lab"])))
            if best is None or d < best[2]:
                best = (i, j, d)
    return best


def nearest_for(idx):
    me = samples[idx]
    others = [s for k, s in enumerate(samples) if k != idx]
    if not others:
        return None
    return min(float(np.linalg.norm(np.array(me["lab"]) - np.array(o["lab"]))) for o in others)


def sample_at(frame, x, y, name):
    h, w = frame.shape[:2]
    x, y = max(0, min(w - 1, int(x))), max(0, min(h - 1, int(y)))
    r = SAMPLE_PATCH // 2
    patch = frame[max(0, y - r):min(h, y + r + 1), max(0, x - r):min(w, x + r + 1)]
    if patch.size == 0:
        return None
    bgr = np.median(patch.reshape(-1, 3), axis=0)
    return {"name": name, "x": x, "y": y, "lab": lab_of(patch),
            "rgb": [int(bgr[2]), int(bgr[1]), int(bgr[0])]}


def snapshot_state():
    with state_lock:
        items = [dict(s) for s in samples]
        wp = worst_pair(items)
        for k, s in enumerate(items):
            s["nearest"] = nearest_for(k)
        return {
            "settings": dict(settings),
            "samples": items,
            "palette": BLOCK_COLORS,
            "next": BLOCK_COLORS[len(items)] if len(items) < len(BLOCK_COLORS) else None,
            "worst": None if wp is None else
                     {"a": items[wp[0]]["name"], "b": items[wp[1]]["name"], "de": wp[2]},
            "good_de": GOOD_DE,
            "path": str(SETTINGS_PATH),
        }


# ---- camera ----------------------------------------------------------------------

def grab_loop(stop):
    while not stop.is_set():
        ok, frame = cap.read()
        if ok:
            latest["frame"] = frame
        else:
            time.sleep(0.01)


def resample_all():
    frame = latest["frame"]
    if frame is None:
        return
    with state_lock:
        for s in samples:
            fresh = sample_at(frame, s["x"], s["y"], s["name"])
            if fresh:
                s["lab"], s["rgb"] = fresh["lab"], fresh["rgb"]


# ---- the page --------------------------------------------------------------------

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>camera tune</title>
<style>
 :root{color-scheme:dark}
 body{margin:0;background:#12141a;color:#e8e8ee;font:14px/1.45 system-ui,sans-serif}
 .wrap{display:flex;gap:18px;padding:18px;align-items:flex-start;flex-wrap:wrap}
 .feed{position:relative;flex:1 1 640px;min-width:320px}
 img{width:100%;display:block;border-radius:10px;cursor:crosshair;background:#000}
 .side{flex:0 0 330px;min-width:290px}
 h1{font-size:16px;margin:0 0 4px}
 .hint{color:#9aa;font-size:12px;margin:0 0 14px}
 .row{margin:10px 0}
 .row label{display:flex;justify-content:space-between;font-size:12px;color:#bcc}
 .row .note{color:#7d8694;font-size:11px}
 input[type=range]{width:100%}
 button{background:#232733;color:#e8e8ee;border:1px solid #39405120;border-radius:7px;
        padding:7px 11px;font-size:13px;cursor:pointer;margin:2px 4px 2px 0}
 button:hover{background:#2d3340}
 #score{font-size:22px;font-weight:650;margin:2px 0 2px}
 #scoresub{font-size:12px;color:#9aa;margin-bottom:10px}
 .chips{display:flex;flex-wrap:wrap;gap:7px;margin-top:8px}
 .chip{border:1px solid #39405160;border-radius:8px;padding:5px 7px;min-width:86px}
 .sw{height:26px;border-radius:5px;border:1px solid #0006}
 .cn{font-size:11px;color:#cdd;margin-top:3px}
 .de{font-size:11px;font-weight:600}
 .ok{color:#6fe39a}.bad{color:#ffab66}
 .marks{position:absolute;inset:0;pointer-events:none}
 .mk{position:absolute;width:20px;height:20px;margin:-10px 0 0 -10px;border:2px solid #fff;
     border-radius:50%;box-shadow:0 0 0 1px #000}
 .mk span{position:absolute;left:23px;top:0;font-size:11px;color:#fff;text-shadow:0 1px 2px #000;white-space:nowrap}
</style></head><body>
<div class="wrap">
 <div class="feed"><img id="v" src="/stream.mjpg"><div class="marks" id="marks"></div></div>
 <div class="side">
  <h1>camera tune</h1>
  <p class="hint">Click each cube once, in this order. Then move the sliders until the
   worst-pair number stops going up, and Save.</p>
  <div id="score">--</div><div id="scoresub">no samples yet</div>
  <div>
   <button onclick="act('/undo')">Undo</button>
   <button onclick="act('/clear')">Clear</button>
   <button onclick="act('/resample')">Re-sample</button>
   <button onclick="act('/defaults')">Defaults</button>
   <button onclick="act('/save')" style="background:#2b4a33">Save</button>
  </div>
  <div id="sliders"></div>
  <div class="row">
   <button onclick="toggle('auto_exposure')">auto-exposure: <b id="ae">?</b></button>
   <button onclick="toggle('auto_wb')">auto-WB: <b id="aw">?</b></button>
  </div>
  <div class="chips" id="chips"></div>
  <p class="hint" id="path"></p>
 </div>
</div>
<script>
const SL = __SLIDERS__;
let st = null;
const sliders = document.getElementById('sliders');
for (const [name, lo, hi, def, note] of SL) {
  const d = document.createElement('div'); d.className = 'row';
  d.innerHTML = `<label><span>${name}</span><span id="val_${name}">--</span></label>
   <input type="range" id="sl_${name}" min="${lo}" max="${hi}" value="${def}">
   ${note ? `<div class="note">${note}</div>` : ''}`;
  sliders.appendChild(d);
  const el = d.querySelector('input');
  el.addEventListener('input', () => {
    document.getElementById('val_' + name).textContent = el.value;
    fetch(`/set?k=${name}&v=${el.value}`).then(refresh);
  });
}
function act(u){ fetch(u).then(refresh); }
function toggle(k){ fetch('/toggle?k=' + k).then(refresh); }
document.getElementById('v').addEventListener('click', e => {
  const img = e.target, r = img.getBoundingClientRect();
  const x = Math.round((e.clientX - r.left) / r.width * img.naturalWidth);
  const y = Math.round((e.clientY - r.top) / r.height * img.naturalHeight);
  fetch(`/sample?x=${x}&y=${y}`).then(refresh);
});
function refresh(){ return fetch('/state').then(r => r.json()).then(draw); }
function draw(s){
  st = s;
  document.getElementById('path').textContent = 'saves to ' + s.path;
  for (const [name] of SL) {
    const v = s.settings[name];
    if (v === undefined) continue;
    const el = document.getElementById('sl_' + name);
    if (document.activeElement !== el) el.value = v;
    document.getElementById('val_' + name).textContent = v;
  }
  document.getElementById('ae').textContent = (s.settings.auto_exposure >= 0.5) ? 'ON' : 'off';
  document.getElementById('aw').textContent = (s.settings.auto_wb >= 0.5) ? 'ON' : 'off';
  const sc = document.getElementById('score'), sub = document.getElementById('scoresub');
  if (s.worst) {
    sc.textContent = 'dE ' + s.worst.de.toFixed(1);
    sc.className = s.worst.de >= s.good_de ? 'ok' : 'bad';
    sub.textContent = `worst pair: ${s.worst.a} vs ${s.worst.b}` +
      (s.worst.de >= s.good_de ? ' — good enough' : ` — aim for ${s.good_de}+`);
  } else {
    sc.textContent = '--'; sc.className = '';
    sub.textContent = s.next ? ('click the ' + s.next + ' cube') : 'no samples yet';
  }
  const chips = document.getElementById('chips'); chips.innerHTML = '';
  for (const c of s.samples) {
    const d = document.createElement('div'); d.className = 'chip';
    const near = c.nearest == null ? '' :
      `<div class="de ${c.nearest >= s.good_de ? 'ok' : 'bad'}">dE ${c.nearest.toFixed(0)}</div>`;
    d.innerHTML = `<div class="sw" style="background:rgb(${c.rgb.join(',')})"></div>
                   <div class="cn">${c.name}</div>${near}`;
    chips.appendChild(d);
  }
  const img = document.getElementById('v'), marks = document.getElementById('marks');
  marks.innerHTML = '';
  if (img.naturalWidth) for (const c of s.samples) {
    const m = document.createElement('div'); m.className = 'mk';
    m.style.left = (c.x / img.naturalWidth * 100) + '%';
    m.style.top = (c.y / img.naturalHeight * 100) + '%';
    m.innerHTML = `<span>${c.name}</span>`;
    marks.appendChild(m);
  }
}
refresh(); setInterval(refresh, 1500);
</script></body></html>"""


class Quiet(ThreadingHTTPServer):
    """A browser that reloads or closes a tab aborts the MJPEG connection mid-write, and
    socketserver's default handler prints a full ConnectionAbortedError traceback for it. That
    is normal operation here, not a fault, and a wall of tracebacks hides the sampling output
    this tool exists to show."""

    daemon_threads = True

    def handle_error(self, request, client_address):
        import sys
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionAbortedError, ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass   # the console is for the tuning readout, not a request log

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    def _send(self, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        path = u.path

        if path == "/":
            page = PAGE.replace("__SLIDERS__", json.dumps(
                [[n, lo, hi, d, note] for n, lo, hi, d, note in SLIDERS]))
            return self._send(page, "text/html; charset=utf-8")

        if path == "/stream.mjpg":
            return self._stream()

        if path == "/state":
            return self._send(json.dumps(snapshot_state()))

        if path == "/set":
            k, v = q.get("k", [""])[0], q.get("v", [""])[0]
            if k in SETTING_PROPS:
                try:
                    val = float(v)
                except ValueError:
                    return self._send(json.dumps({"ok": False}))
                with state_lock:
                    settings[k] = int(val) if float(val).is_integer() else val
                cap.set(SETTING_PROPS[k], val)
                resample_all()
            return self._send(json.dumps({"ok": True}))

        if path == "/toggle":
            k = q.get("k", [""])[0]
            if k in ("auto_exposure", "auto_wb"):
                with state_lock:
                    on = settings.get(k, 0) >= 0.5
                    settings[k] = (0.25 if k == "auto_exposure" else 0.0) if on else \
                                  (0.75 if k == "auto_exposure" else 1.0)
                    val = settings[k]
                cap.set(SETTING_PROPS[k], val)
            return self._send(json.dumps({"ok": True}))

        if path == "/sample":
            frame = latest["frame"]
            if frame is not None:
                with state_lock:
                    room = len(samples) < len(BLOCK_COLORS)
                    name = BLOCK_COLORS[len(samples)] if room else None
                if name:
                    s = sample_at(frame, int(q.get("x", [0])[0]), int(q.get("y", [0])[0]), name)
                    if s:
                        with state_lock:
                            samples.append(s)
                        print(f"  sampled {name:<11} at ({s['x']},{s['y']})")
            return self._send(json.dumps({"ok": True}))

        if path == "/undo":
            with state_lock:
                if samples:
                    print(f"  removed {samples.pop()['name']}")
            return self._send(json.dumps({"ok": True}))

        if path == "/clear":
            with state_lock:
                samples.clear()
            return self._send(json.dumps({"ok": True}))

        if path == "/resample":
            resample_all()
            return self._send(json.dumps({"ok": True}))

        if path == "/defaults":
            with state_lock:
                settings.update(DEFAULTS)
                snap = dict(settings)
            apply_settings(cap, snap)
            resample_all()
            return self._send(json.dumps({"ok": True}))

        if path == "/save":
            with state_lock:
                kept = save_settings(settings)
                wp = worst_pair(samples)
                names = [s["name"] for s in samples]
            print(f"  saved {len(kept)} setting(s) to {SETTINGS_PATH}")
            if wp and wp[2] < GOOD_DE:
                print(f"  note: worst pair is still dE {wp[2]:.1f} "
                      f"({names[wp[0]]} vs {names[wp[1]]}) - under {GOOD_DE:.0f} the model "
                      f"will still mix them up")
            return self._send(json.dumps({"ok": True, "saved": kept}))

        self.send_error(404)

    def _stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=f")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            while True:
                frame = latest["frame"]
                if frame is None:
                    time.sleep(0.05)
                    continue
                ok, buf = cv2.imencode(".jpg", frame,
                                       [int(cv2.IMWRITE_JPEG_QUALITY), JPEG_QUALITY])
                if not ok:
                    continue
                data = buf.tobytes()
                self.wfile.write(b"--f\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                 + str(len(data)).encode() + b"\r\n\r\n" + data + b"\r\n")
                time.sleep(1 / 15)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return   # the tab was closed or reloaded


def main():
    global cap
    cap = cv2.VideoCapture(CAMERA_INDEX, cv2.CAP_DSHOW)
    if not cap.isOpened():
        raise SystemExit(f"Can't open camera {CAMERA_INDEX}. Close the Camera app, and stop "
                         f"the bridge if it is running with --vision (it holds the camera).")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_H)

    settings.update(DEFAULTS)
    settings.update(load_settings())
    applied = apply_settings(cap, settings)
    refused = sorted(k for k in settings if k not in applied)
    print(f"camera {CAMERA_INDEX}: {len(applied)} setting(s) accepted"
          + (f", not supported by this driver: {', '.join(refused)}" if refused else ""))

    stop = threading.Event()
    threading.Thread(target=grab_loop, args=(stop,), daemon=True).start()

    srv = Quiet(("127.0.0.1", PORT), Handler)
    url = f"http://localhost:{PORT}"
    print(f"  open {url}   (Ctrl-C here when you are done)")
    print(f"  settings file: {SETTINGS_PATH}")
    webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n  stopped")
    finally:
        stop.set()
        srv.server_close()
        cap.release()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
