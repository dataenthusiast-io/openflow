"""OpenFlow ASR sidecar: streaming Nemotron 3.5 over a Unix socket.

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
DEFAULT_SOCKET = os.path.expanduser("~/Library/Application Support/OpenFlow/asr.sock")
LANG_TAG = re.compile(r"\s*<([a-z]{2,3}-[A-Z]{2})>")

log = logging.getLogger("openflow-asr")


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
    """Two streaming decoders: a fast one for live partials and a slower, more accurate one whose
    result gets pasted. Each needs its own model instance: generate() keeps streaming state on the
    model object, so one instance can't serve two concurrent streams."""

    def __init__(self, device: str, lookahead: int, final_lookahead: int, language: str, dtype: torch.dtype):
        self.device = device
        self.language = language
        self.dtype = dtype
        self.live = self._decoder(lookahead)
        self.final = self._decoder(final_lookahead) if final_lookahead != lookahead else None
        # MPS segfaults when two threads run the model at once: decoders take turns per chunk.
        self.gpu = threading.Lock()
        fe = self.live.feature_extractor
        self.sr, self.hop, self.n_fft = fe.sampling_rate, fe.hop_length, fe.n_fft
        # Trailing silence that pushes the last chunk + right context of the slowest decoder through.
        slowest = self.final or self.live
        self.flush_seconds = slowest.num_samples_per_audio_chunk / self.sr + slowest.streaming_latency_ms / 1000 + 0.1
        log.info(
            "model loaded on %s (%s), live latency %d ms, final latency %s",
            device, dtype, self.live.streaming_latency_ms,
            f"{self.final.streaming_latency_ms} ms" if self.final else "same as live",
        )

    def _decoder(self, lookahead: int):
        p = AutoProcessor.from_pretrained(MODEL_ID)
        p.set_num_lookahead_tokens(lookahead)
        p.model = AutoModelForRNNT.from_pretrained(MODEL_ID, dtype=self.dtype).to(self.device).eval()
        return p

    def warm_up(self):
        s = Session(self, self.language, lambda *_: None)
        s.push(np.zeros(self.sr, dtype=np.int16).tobytes())
        s.end()
        s.join()


class Session:
    """One push-to-talk utterance. Audio is pushed from the socket thread; each decoder pulls it."""

    def __init__(self, engine: Engine, language: str, emit):
        self.e = engine
        self.language = language
        self.emit = emit
        self.audio = np.zeros(0, dtype=np.float32)
        self.cond = threading.Condition()
        self.done = False
        self.cancelled = False
        self.live_result: tuple[str, str | None] = ("", None)
        self.live_done = threading.Event()
        self.threads = [Thread(target=self._run_live, daemon=True)]
        if engine.final:
            self.threads.append(Thread(target=self._run_final, daemon=True))
        for t in self.threads:
            t.start()

    def push(self, pcm: bytes):
        samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        with self.cond:
            self.audio = np.concatenate([self.audio, samples])
            self.cond.notify_all()

    def end(self, cancel: bool = False):
        with self.cond:
            self.cancelled = cancel
            self.audio = np.concatenate([self.audio, np.zeros(int(self.e.flush_seconds * self.e.sr), np.float32)])
            self.done = True
            self.cond.notify_all()

    def join(self):
        for t in self.threads:
            t.join()

    def _wait_for(self, n: int) -> np.ndarray | None:
        """Block until audio[:n] exists. Returns None once the session ended without enough audio."""
        with self.cond:
            self.cond.wait_for(lambda: self.audio.shape[0] >= n or self.done)
            return self.audio if self.audio.shape[0] >= n else None

    def _features(self, p, audio: np.ndarray, first: bool):
        return p(
            audio,
            sampling_rate=self.e.sr,
            is_streaming=True,
            is_first_audio_chunk=first,
            language=self.language,
            return_tensors="pt",
        ).to(self.e.device, dtype=self.e.dtype)

    def _feature_stream(self, p, first_features):
        """Runs inside generate(), which holds the GPU lock; it is released only while waiting for audio."""
        yield first_features
        mel_idx = p.num_mel_frames_first_audio_chunk
        while True:
            start = mel_idx * self.e.hop - self.e.n_fft // 2
            self.e.gpu.release()
            try:
                audio = self._wait_for(start + p.num_samples_per_audio_chunk)
            finally:
                self.e.gpu.acquire()
            if audio is None:
                return
            yield self._features(p, audio[start : start + p.num_samples_per_audio_chunk], False).input_features
            mel_idx += p.num_mel_frames_per_audio_chunk

    def _decode(self, p, on_update=None) -> tuple[str, str | None]:
        """Runs one streaming decoder over the session audio; returns (text, language)."""
        audio = self._wait_for(p.num_samples_first_audio_chunk)
        if audio is None:
            return "", None
        with self.e.gpu:
            first = self._features(p, audio[: p.num_samples_first_audio_chunk], True)
        first_features = first.input_features[:, : p.num_mel_frames_first_audio_chunk, :]
        streamer = LiveStreamer(p.tokenizer, timeout=30)
        errors = []

        def generate():
            try:
                with self.e.gpu, torch.inference_mode():
                    p.model.generate(
                        **{**first, "input_features": self._feature_stream(p, first_features), "streamer": streamer}
                    )
            except Exception as exc:  # surface to the client instead of hanging the streamer
                errors.append(exc)
                streamer.end()

        gen = Thread(target=generate, daemon=True)
        gen.start()
        raw, lang = "", None
        for raw in streamer:
            tags = LANG_TAG.findall(raw)
            lang = tags[-1] if tags else lang
            if on_update:
                on_update(clean(raw), lang)
        gen.join()
        if errors:
            raise errors[0]
        return clean(raw), lang

    def _run_live(self):
        last = None

        def on_update(text, lang):
            nonlocal last
            if text and not self.cancelled and (text, lang) != last:
                self.emit("partial", text, lang)
                last = (text, lang)

        try:
            self.live_result = self._decode(self.e.live, on_update)
        except Exception as exc:
            log.exception("live decoder failed")
            self.emit("error", str(exc), None)
        finally:
            self.live_done.set()
        if not self.e.final and not self.cancelled:
            self.emit("final", *self.live_result)

    def _run_final(self):
        try:
            text, lang = self._decode(self.e.final)
        except Exception:
            log.exception("final decoder failed, falling back to live transcript")
            text, lang = "", None
        if not text:  # nothing better than the live pass
            self.live_done.wait()
            text, lang = self.live_result
        if not self.cancelled:
            self.emit("final", text, lang or self.live_result[1])


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
    ap.add_argument("--lookahead", type=int, default=3, help="live partials: 3 (320 ms), 6 (560 ms), 13 (1.12 s)")
    ap.add_argument("--final-lookahead", type=int, default=13,
                    help="pasted text: a second, more accurate decoder; same as --lookahead = single pass")
    ap.add_argument("--fp32", action="store_true", help="full precision (default fp16: same output, half memory)")
    ap.add_argument("--language", default="auto", help='"auto" or a locale like de-DE')
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

    dtype = torch.float32 if args.fp32 or args.device == "cpu" else torch.float16
    engine = Engine(args.device, args.lookahead, args.final_lookahead, args.language, dtype)
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
