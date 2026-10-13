"""Stream a WAV into the running sidecar at real-time pace and print what comes back.

Usage: uv run smoke.py ../samples/de.wav [--socket PATH] [--fast]
"""

import argparse
import json
import socket
import struct
import threading
import time
import wave

from server import DEFAULT_SOCKET


def frame(kind: bytes, payload: bytes = b"") -> bytes:
    return kind + struct.pack(">I", len(payload)) + payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    ap.add_argument("--socket", default=DEFAULT_SOCKET)
    ap.add_argument("--fast", action="store_true", help="send without real-time pacing")
    args = ap.parse_args()

    with wave.open(args.wav, "rb") as w:
        pcm = w.readframes(w.getnframes())

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(args.socket)
    f = s.makefile("r", encoding="utf-8")
    print(json.loads(f.readline()))
    t_end = [None]
    sent = [0.0]  # seconds of audio sent so far
    done = threading.Event()

    def reader():
        t0 = time.perf_counter()
        for line in f:
            msg = json.loads(line)
            el = time.perf_counter() - t0
            if msg["type"] == "final":
                print(f"[{el:5.2f}s] FINAL ({(time.perf_counter() - t_end[0]) * 1000:.0f} ms after release) {msg}")
                done.set()
                return
            print(f"[{el:5.2f}s audio={sent[0]:4.1f}s] {msg.get('lang')}  {msg.get('text', msg)}")

    threading.Thread(target=reader, daemon=True).start()
    s.sendall(frame(b"S"))
    step = 1600 * 2  # 100 ms of int16 audio, like an AVAudioEngine tap
    for i in range(0, len(pcm), step):
        s.sendall(frame(b"A", pcm[i : i + step]))
        sent[0] = (i + step) / 32000
        if not args.fast:
            time.sleep(0.1)
    t_end[0] = time.perf_counter()
    s.sendall(frame(b"E"))
    done.wait(30)
    s.close()


if __name__ == "__main__":
    main()
