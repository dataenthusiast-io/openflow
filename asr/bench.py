"""Benchmark Nemotron 3.5 streaming ASR on local WAV files.

Usage: uv run bench.py ../samples/*.wav [--device mps|cpu] [--lookahead 6]
Reports transcript (with language tag), real-time factor and per-chunk compute.
"""

import argparse
import time
import wave
from threading import Thread

import numpy as np
import torch
from transformers import AutoModelForRNNT, AutoProcessor, TextIteratorStreamer

MODEL_ID = "nvidia/nemotron-3.5-asr-streaming-0.6b"


def load_wav(path: str, sr: int) -> np.ndarray:
    with wave.open(path, "rb") as w:
        assert w.getframerate() == sr and w.getnchannels() == 1 and w.getsampwidth() == 2, (
            f"{path}: need 16 kHz mono int16"
        )
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0


def stream(model, processor, audio, language, dtype):
    sr = processor.feature_extractor.sampling_rate
    hop = processor.feature_extractor.hop_length
    n_fft = processor.feature_extractor.n_fft
    chunk_times = []

    first = processor(
        audio[: processor.num_samples_first_audio_chunk],
        sampling_rate=sr,
        is_streaming=True,
        is_first_audio_chunk=True,
        language=language,
        return_tensors="pt",
    ).to(model.device, dtype=dtype)

    def features():
        t = time.perf_counter()
        yield first.input_features[:, : processor.num_mel_frames_first_audio_chunk, :]
        mel_idx = processor.num_mel_frames_first_audio_chunk
        start = mel_idx * hop - n_fft // 2
        while (end := start + processor.num_samples_per_audio_chunk) < audio.shape[0]:
            inputs = processor(
                audio[start:end],
                sampling_rate=sr,
                is_streaming=True,
                is_first_audio_chunk=False,
                language=language,
                return_tensors="pt",
            ).to(model.device, dtype=dtype)
            now = time.perf_counter()
            chunk_times.append(now - t)
            t = now
            yield inputs.input_features
            mel_idx += processor.num_mel_frames_per_audio_chunk
            start = mel_idx * hop - n_fft // 2

    streamer = TextIteratorStreamer(processor.tokenizer, skip_special_tokens=False)
    thread = Thread(target=model.generate, kwargs={**first, "input_features": features(), "streamer": streamer})
    thread.start()
    text = "".join(streamer)
    thread.join()
    return text, chunk_times


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wavs", nargs="+")
    ap.add_argument("--device", default="mps")
    ap.add_argument("--lookahead", type=int, default=6, help="right context: 0,3,6,13")
    ap.add_argument("--language", default="auto")
    ap.add_argument("--fp16", action="store_true")
    args = ap.parse_args()

    dtype = torch.float16 if args.fp16 else torch.float32
    t0 = time.perf_counter()
    processor = AutoProcessor.from_pretrained(MODEL_ID)
    model = AutoModelForRNNT.from_pretrained(MODEL_ID, dtype=dtype).to(args.device).eval()
    processor.set_num_lookahead_tokens(args.lookahead)
    print(f"load {time.perf_counter() - t0:.1f}s  device={args.device} dtype={dtype}  "
          f"latency={processor.streaming_latency_ms}ms  "
          f"chunk={processor.num_samples_per_audio_chunk / 16000 * 1000:.0f}ms")

    sr = processor.feature_extractor.sampling_rate
    stream(model, processor, load_wav(args.wavs[0], sr), args.language, dtype)  # warm-up

    for path in args.wavs:
        audio = load_wav(path, sr)
        dur = audio.shape[0] / sr
        # Trailing silence flushes the last partial chunk + right context through the encoder.
        audio = np.concatenate([audio, np.zeros(int(1.5 * sr), dtype=np.float32)])
        t = time.perf_counter()
        with torch.inference_mode():
            text, chunk_times = stream(model, processor, audio, args.language, dtype)
        el = time.perf_counter() - t
        ct = np.array(chunk_times[1:]) * 1000 if len(chunk_times) > 1 else np.array([0.0])
        print(f"\n{path}  audio={dur:.1f}s  wall={el:.2f}s  RTF={el / dur:.3f}  "
              f"chunk compute mean={ct.mean():.0f}ms max={ct.max():.0f}ms")
        print(f"  -> {text.strip()}")


if __name__ == "__main__":
    main()
