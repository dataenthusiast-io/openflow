"""Flow ASR sidecar: streaming Nemotron 3.5 over a Unix socket.

Client -> server frames: 1 byte type + 4 byte big-endian length + payload
    b"S"  start session (payload: optional language, e.g. b"de-DE"; empty = server default)
    b"A"  audio: 16 kHz mono int16 little-endian PCM
    b"E"  end session: flush and emit final
    b"X"  cancel session: flush silently
Server -> client: newline-delimited JSON
    {"type": "ready"}
    {"type": "partial", "text": "...", "lang": "de-DE"}
    {"type": "final", "text": "...", "lang": "de-DE"}
    {"type": "error", "message": "..."}
"""

import argparse
import json
import logging
import os
import queue
import re
import socket
import struct
import threading
import time
from threading import Thread

import numpy as np
import torch
from transformers import AutoModelForRNNT, AutoProcessor
from transformers.generation.streamers import BaseStreamer

MODEL_ID = "nvidia/nemotron-3.5-asr-streaming-0.6b"
DEFAULT_SOCKET = os.path.expanduser("~/Library/Application Support/Flow/asr.sock")
LANG_TAG = re.compile(r"\s*<([a-z]{2,3}-[A-Z]{2})>")
# Trailing silence that pushes the last partial chunk + right context through the encoder.
FLUSH_SECONDS = 1.0

log = logging.getLogger("flow-asr")


class LiveStreamer(BaseStreamer):
    """Yields the full decoded transcript after every token.

    transformers' TextIteratorStreamer holds text back until the next space, so the word being
    spoken stays invisible until the following word starts.
    """

    def __init__(self, tokenizer, timeout: float):
        self.tokenizer = tokenizer
        self.tokens: list[int] = []
        self.queue: queue.Queue[str | None] = queue.Queue()
        self.timeout = timeout

    def put(self, value):
        self.tokens.extend(value.reshape(-1).tolist())
        self.queue.put(self.tokenizer.decode(self.tokens, skip_special_tokens=False))

    def end(self):
        self.queue.put(None)

    def __iter__(self):
        while (text := self.queue.get(timeout=self.timeout)) is not None:
            yield text


class Engine:
    def __init__(self, device: str, lookahead: int, language: str):
        self.device = device
        self.language = language
        self.processor = AutoProcessor.from_pretrained(MODEL_ID)
        self.model = AutoModelForRNNT.from_pretrained(MODEL_ID, dtype=torch.float32).to(device).eval()
        self.processor.set_num_lookahead_tokens(lookahead)
        fe = self.processor.feature_extractor
        self.sr, self.hop, self.n_fft = fe.sampling_rate, fe.hop_length, fe.n_fft
        self.lock = threading.Lock()  # one generate() at a time
        log.info("model loaded on %s, streaming latency %d ms", device, self.processor.streaming_latency_ms)

    def warm_up(self):
        s = Session(self, self.language, lambda *_: None)
        s.push(np.zeros(self.sr, dtype=np.int16).tobytes())
        s.end()
        s.join()


class Session:
    """One push-to-talk utterance. Audio is pushed from the socket thread; generate() pulls it."""

    def __init__(self, engine: Engine, language: str, emit):
        self.e = engine
        self.language = language
        self.emit = emit
        self.audio = np.zeros(0, dtype=np.float32)
        self.cond = threading.Condition()
        self.done = False
        self.cancelled = False
        self.thread = Thread(target=self._run, daemon=True)
        self.thread.start()

    def push(self, pcm: bytes):
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        with self.cond:
            self.audio = np.concatenate([self.audio, samples])
            self.cond.notify_all()

    def end(self, cancel: bool = False):
        with self.cond:
            self.cancelled = cancel
            self.audio = np.concatenate([self.audio, np.zeros(int(FLUSH_SECONDS * self.e.sr), np.float32)])
            self.done = True
            self.cond.notify_all()

    def join(self):
        self.thread.join()

    def _wait_for(self, n: int) -> np.ndarray | None:
        """Block until audio[:n] exists. Returns None once the session ended without enough audio."""
        with self.cond:
            self.cond.wait_for(lambda: self.audio.shape[0] >= n or self.done)
            return self.audio if self.audio.shape[0] >= n else None

    def _features(self, audio: np.ndarray, first: bool):
        return self.e.processor(
            audio,
            sampling_rate=self.e.sr,
            is_streaming=True,
            is_first_audio_chunk=first,
            language=self.language,
            return_tensors="pt",
        ).to(self.e.device, dtype=torch.float32)

    def _feature_stream(self, first_features):
        p = self.e.processor
        yield first_features
        mel_idx = p.num_mel_frames_first_audio_chunk
        while True:
            start = mel_idx * self.e.hop - self.e.n_fft // 2
            audio = self._wait_for(start + p.num_samples_per_audio_chunk)
            if audio is None:
                return
            yield self._features(audio[start : start + p.num_samples_per_audio_chunk], False).input_features
            mel_idx += p.num_mel_frames_per_audio_chunk

    def _run(self):
        p = self.e.processor
        audio = self._wait_for(p.num_samples_first_audio_chunk)
        if audio is None:
            return self._finish("", None)
        first = self._features(audio[: p.num_samples_first_audio_chunk], True)
        first_features = first.input_features[:, : p.num_mel_frames_first_audio_chunk, :]

        streamer = LiveStreamer(p.tokenizer, timeout=30)
        errors = []

        def generate():
            try:
                with torch.inference_mode():
                    self.e.model.generate(
                        **{**first, "input_features": self._feature_stream(first_features), "streamer": streamer}
                    )
            except Exception as exc:  # surface to the client instead of hanging the streamer
                errors.append(exc)
                streamer.end()

        raw, lang, last = "", None, None
        with self.e.lock:
            gen = Thread(target=generate, daemon=True)
            gen.start()
            for raw in streamer:
                tags = LANG_TAG.findall(raw)
                lang = tags[-1] if tags else lang
                text = clean(raw)
                if not self.cancelled and (text, lang) != last and text:
                    self.emit("partial", text, lang)
                    last = (text, lang)
            gen.join()
        if errors:
            log.exception("generate failed", exc_info=errors[0])
            self.emit("error", str(errors[0]), None)
        self._finish(clean(raw), lang)

    def _finish(self, text: str, lang: str | None):
        if not self.cancelled:
            self.emit("final", text, lang)


def clean(raw: str) -> str:
    return re.sub(r"\s+", " ", LANG_TAG.sub("", raw)).strip()


def recv_exact(conn: socket.socket, n: int) -> bytes | None:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def serve_client(engine: Engine, conn: socket.socket):
    wlock = threading.Lock()

    def send(msg: dict):
        with wlock:
            try:
                conn.sendall((json.dumps(msg, ensure_ascii=False) + "\n").encode())
            except OSError:
                pass

    def emit(kind, text, lang):
        if kind == "error":
            send({"type": "error", "message": text})
        else:
            send({"type": kind, "text": text, "lang": lang})

    send({"type": "ready"})
    session = None
    while (header := recv_exact(conn, 5)) is not None:
        kind, length = header[:1], struct.unpack(">I", header[1:])[0]
        payload = recv_exact(conn, length) if length else b""
        if payload is None:
            break
        if kind == b"S":
            if session:
                session.end(cancel=True)
            t = time.perf_counter()
            session = Session(engine, payload.decode() or engine.language, emit)
            log.info("session start (%.0f ms)", (time.perf_counter() - t) * 1000)
        elif kind == b"A" and session:
            session.push(payload)
        elif kind in (b"E", b"X") and session:
            session.end(cancel=kind == b"X")
            session = None
    if session:
        session.end(cancel=True)
    conn.close()
    log.info("client disconnected")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default=DEFAULT_SOCKET)
    ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    ap.add_argument("--lookahead", type=int, default=3, help="right context tokens: 0, 3 (320 ms), 6, 13")
    ap.add_argument("--language", default="auto", help='"auto" or a locale like de-DE')
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

    engine = Engine(args.device, args.lookahead, args.language)
    engine.warm_up()

    os.makedirs(os.path.dirname(args.socket), exist_ok=True)
    if os.path.exists(args.socket):
        os.unlink(args.socket)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.socket)
    srv.listen(4)
    log.info("listening on %s", args.socket)
    while True:
        conn, _ = srv.accept()
        log.info("client connected")
        Thread(target=serve_client, args=(engine, conn), daemon=True).start()


if __name__ == "__main__":
    main()
