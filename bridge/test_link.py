"""End-to-end check of the bridge, with a headless client standing in for Roblox.

    python -m bridge.main --source mock          # in one terminal
    python -m bridge.test_link                   # in another

It does exactly what a Roblox script does: connect, read the hello frame, consume state
frames, send an event, and confirm the event came back as an active effect. If this passes,
the only thing left between here and Studio is the Lua.
"""

import asyncio
import json
import statistics
import sys
import time

import websockets

from . import protocol


# Long enough to cover a whole mock cycle. The mock picks a block up at about t=4 s and sets
# it down again at about t=17 s, so a short window can connect during a phase where nothing is
# held or stacked and then fail for no reason. The sampling loop stops as soon as it has seen
# both, so a passing run is still quick.
SAMPLE_S = 24.0


async def main(url=f"ws://localhost:{protocol.WS_PORT}", seconds=SAMPLE_S):
    print(f"connecting to {url}")
    try:
        conn = await asyncio.wait_for(websockets.connect(url), timeout=4.0)
    except (OSError, asyncio.TimeoutError) as e:
        print(f"FAIL  could not connect: {e}\n      is `python -m bridge.main --source mock` running?")
        return 1

    checks = []

    def check(label, ok, detail=""):
        print(f"  {'PASS' if ok else 'FAIL'}  {label}{(' — ' + detail) if detail else ''}")
        checks.append(ok)
        return ok

    async with conn:
        raw = await asyncio.wait_for(conn.recv(), timeout=4.0)
        hello = json.loads(raw)
        check("hello arrives first", hello.get("t") == "hello", hello.get("t"))
        check("protocol version matches", hello.get("v") == protocol.VERSION, str(hello.get("v")))
        check("hello carries sheet geometry", bool(hello.get("space", {}).get("sheet")))
        check("hello lists the effects", len(hello.get("effects", [])) >= 6,
              ", ".join(hello.get("effects", [])))
        space = hello.get("space", {})
        print(f"        source={hello.get('source')} cube={space.get('cube_mm')} mm "
              f"arm_base={space.get('arm_base_mm')} mm")

        seqs, gaps, held_seen, levels_seen, ids_seen = [], [], False, set(), set()
        points_len = set()
        last_t = None
        t0 = time.perf_counter()
        sent_event = False
        effect_seen = False

        while time.perf_counter() - t0 < seconds:
            # Stop as soon as everything interesting has been observed.
            if held_seen and max(levels_seen, default=0) > 0 and effect_seen and len(seqs) > 30:
                break
            raw = await asyncio.wait_for(conn.recv(), timeout=4.0)
            f = json.loads(raw)
            if f.get("t") == "pong":
                continue
            if f.get("t") != "state":
                continue
            seqs.append(f["seq"])
            now = time.perf_counter()
            if last_t is not None:
                gaps.append(now - last_t)
            last_t = now

            arm = f.get("arm")
            if arm:
                points_len.add(len(arm.get("points", [])))
            for b in f.get("blocks", []):
                ids_seen.add(b["id"])
                levels_seen.add(b["level"])
                if b["held"]:
                    held_seen = True

            if not sent_event and now - t0 > 1.0:
                await conn.send(json.dumps({"t": "event", "name": "earthquake",
                                            "intensity": 0.7, "duration": 3}))
                sent_event = True
                print("        sent: earthquake 0.7 for 3 s")
            if sent_event and any(e["name"] == "earthquake" for e in f.get("effects", [])):
                effect_seen = True

        check("state frames arrive", len(seqs) > 30, f"{len(seqs)} frames")
        check("sequence numbers are gapless",
              seqs == list(range(seqs[0], seqs[0] + len(seqs))) if seqs else False)
        if gaps:
            hz = 1 / statistics.mean(gaps)
            worst = max(gaps) * 1000
            check("rate is near the configured 30 Hz", 24 <= hz <= 34, f"{hz:.1f} Hz")
            check("no frame gap over 150 ms", worst < 150, f"worst {worst:.0f} ms")
        check("arm is a 6-point stick figure", points_len == {6}, str(points_len))
        check("blocks have stable ids", ids_seen == {1, 2}, str(sorted(ids_seen)))
        check("a held block was observed", held_seen)
        check("a stacked block was observed (level > 0)", max(levels_seen, default=0) > 0,
              f"levels {sorted(levels_seen)}")
        check("the event came back as an active effect", effect_seen)

        await conn.send(json.dumps({"t": "event", "name": "nonsense"}))
        reply = json.loads(await asyncio.wait_for(conn.recv(), timeout=3.0))
        while reply.get("t") == "state":
            reply = json.loads(await asyncio.wait_for(conn.recv(), timeout=3.0))
        check("an unknown effect is rejected, not crashed on", reply.get("t") == "error",
              reply.get("message", ""))

    print(f"\n{sum(checks)}/{len(checks)} checks passed")
    return 0 if all(checks) else 1


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else f"ws://localhost:{protocol.WS_PORT}"
    raise SystemExit(asyncio.run(main(url)))
