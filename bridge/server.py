"""The WebSocket server Roblox connects to, plus a tiny HTTP server for the mock viewer.

Roblox Studio connects *out* to this process:

    local ws = HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
        Url = "ws://localhost:8765",
    })

so there is no middle server. The process that owns the follower's COM port is the server,
which it has to be: only one process can hold that port, so a separate "reader" service is
not an option.

Threading. Producers run in plain threads because they talk to blocking hardware (a serial
bus, a camera). The server runs asyncio. They never call each other: producers publish into a
StateBus and the broadcast task reads the latest snapshot on its own clock. A camera frame
that takes 150 ms cannot stall the wire, and a client that stops reading cannot stall the arm.
"""

import asyncio
import json
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import websockets

from . import protocol

VIEWER_DIR = Path(__file__).resolve().parent.parent / "viewer"


class Hub:
    """The connected clients, and what to do with what they send."""

    def __init__(self, bus, inbox, effects, space, source, board=None):
        self.bus, self.inbox, self.effects = bus, inbox, effects
        self.space, self.source = space, source
        self.board = board or {}
        self.clients = set()
        self.sent = 0

    async def handle(self, conn):
        peer = getattr(conn, "remote_address", None)
        self.clients.add(conn)
        print(f"  client connected: {peer}  ({len(self.clients)} total)")
        try:
            await conn.send(json.dumps(protocol.hello(
                self.space, self.source, effects=sorted(self.effects.LIMITS),
                board=self.board)))
            async for raw in conn:
                await self._on_message(conn, raw)
        except websockets.ConnectionClosed:
            pass
        finally:
            self.clients.discard(conn)
            print(f"  client gone: {peer}  ({len(self.clients)} left)")

    async def _on_message(self, conn, raw):
        try:
            frame = json.loads(raw)
        except (ValueError, TypeError):
            await conn.send(json.dumps(protocol.error("not JSON", str(raw)[:120])))
            return
        if not isinstance(frame, dict):
            await conn.send(json.dumps(protocol.error("frame is not an object")))
            return

        kind = frame.get("t")
        if kind == "ping":
            await conn.send(json.dumps(protocol.pong(frame.get("id"), asyncio.get_event_loop().time())))
            return
        if kind == "read_board":
            # "Read the board now", from a key in the game. A cube moved by hand never opens
            # the jaw, so no release fires and the board keeps reporting where things used to
            # be. Handled here rather than queued: the board thread owns its own trigger and
            # the producer has nothing to do with it.
            from .producers import board as board_producer
            if board_producer.request_now():
                print("  read_board: requested from a client")
            else:
                await conn.send(json.dumps(protocol.error(
                    "no board thread: mock mode, or started without --vision")))
            return
        if kind == "event":
            # The producer owns the effect stack (it applies effects in the robot thread), so
            # the frame is queued rather than applied here.
            name = frame.get("name")
            if name not in self.effects.LIMITS:
                await conn.send(json.dumps(protocol.error(f"unknown effect {name!r}")))
                return
            print(f"  event: {name} intensity={frame.get('intensity', 1.0)} "
                  f"duration={frame.get('duration', 3.0)}")
        elif kind not in ("mode", "place", "hello"):
            await conn.send(json.dumps(protocol.error(f"unknown frame type {kind!r}")))
            return
        self.inbox.put(frame)

    async def broadcast(self, stop, hz):
        """One state frame to every client, on a fixed clock."""
        period = 1.0 / hz
        loop = asyncio.get_event_loop()
        next_tick = loop.time()
        while not stop.is_set():
            next_tick += period
            await asyncio.sleep(max(0.0, next_tick - loop.time()))
            if not self.clients:
                continue
            payload = json.dumps(self.bus.snapshot(self.effects.describe()))
            dead = []
            for conn in list(self.clients):
                try:
                    await conn.send(payload)
                    self.sent += 1
                except (websockets.ConnectionClosed, RuntimeError):
                    dead.append(conn)
            for conn in dead:
                self.clients.discard(conn)


def viewer_server(bus, effects, port, ws_port):
    """Serves viewer/ so the mock Roblox page can be opened in a browser, and GET /state as
    a debug read (handy for `curl` while the WebSocket is busy). Nothing depends on /state."""

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(VIEWER_DIR), **kw)

        def do_GET(self):
            if self.path.split("?")[0] == "/state":
                body = json.dumps(bus.snapshot(effects.describe()), indent=2).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/":
                self.path = f"/index.html?ws={ws_port}"
            return super().do_GET()

        def log_message(self, *a):
            pass            # the state stream is noisy enough

    httpd = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


async def serve(bus, inbox, effects, space, source, stop, ws_port=protocol.WS_PORT,
                board=None,
                hz=protocol.STATE_HZ):
    hub = Hub(bus, inbox, effects, space, source, board=board)
    async with websockets.serve(hub.handle, "0.0.0.0", ws_port, ping_interval=20,
                                max_queue=8):
        await hub.broadcast(stop, hz)
