"""Two-way source sync between disk and Roblox Studio.

GET  /<name>.lua   -> serve a file from src/ (disk -> Studio)
POST /<name>.lua   -> write the body into src/ (Studio -> disk)

The repo's lebot_obby/README.md says to mirror Studio edits back out and verify with a
checksum because transcription drifts silently. This removes the transcription step entirely:
the bytes that go in are the bytes that come out, and the caller compares length and byte sum
on both sides to prove it.
"""
import http.server, pathlib, sys

SRC = pathlib.Path(__file__).parent / "src"
SRC.mkdir(exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        return str(SRC / pathlib.PurePosixPath(path.split("?")[0]).name)

    def do_POST(self):
        name = pathlib.PurePosixPath(self.path.split("?")[0]).name
        if not name.endswith(".lua"):
            self.send_error(400, "only .lua")
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        (SRC / name).write_bytes(body)
        print(f"  <- {name}: {len(body)} bytes, bytesum {sum(body)}")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"{len(body)} {sum(body)}".encode())

    def log_message(self, fmt, *args):
        if "POST" not in fmt % args:
            print("  -> " + (fmt % args))


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8767
print(f"[sync] src={SRC} on http://127.0.0.1:{port}  (GET pulls, POST pushes)")
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
