<img src="app/Resources/AppIcon.png" width="96" align="right" alt="Flow icon">

# Flow

Local hold-to-talk dictation for macOS. Hold **right ⌥**, speak German or English, release, and the
text is pasted into whatever field has focus: Claude, Slack, a browser, anything.

- **Fully local:** NVIDIA [Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)
  runs on the Apple GPU (MPS), with the language auto-detected per utterance (40 locales).
- **Streaming:** a Liquid Glass HUD shows the transcript live while you speak. New words blur in, and a
  badge shows the detected language.
- **Clean output:** fillers (äh, ähm, öh, hm; um, uh, erm in English) are removed, and your clipboard
  is restored after pasting.

## Requirements
- Apple Silicon Mac, macOS 15+ (macOS 26 for the Liquid Glass look; older versions fall back to a blur material)
- Swift 6 toolchain (Xcode or the Command Line Tools: `xcode-select --install`)
- [uv](https://docs.astral.sh/uv/) (`brew install uv`)
- ~3 GB disk for the model and Python environment

## Setup
```bash
cd asr && uv sync                     # Python 3.12 env: torch, transformers, librosa
uv run bench.py ../samples/*.wav      # downloads the model (~2.4 GB) once and benchmarks it
cd ..
scripts/make-cert.sh                  # optional, once: stable code signature (see below)
scripts/build-app.sh && open build/Flow.app
```
On first launch, grant permissions in **System Settings → Privacy & Security**:
- **Microphone** to capture audio
- **Accessibility** to paste with ⌘V
- **Input Monitoring** for the global hotkey

Quit and reopen Flow after granting them. The menu bar icon has a status line, Restart ASR,
Open ASR Log and Launch at Login.

**Why make-cert?** Without a stable signature, every rebuild is a "new" app to macOS, and the three
permissions have to be granted again. `make-cert.sh` creates a self-signed "Flow Dev" code-signing
certificate in your login keychain (asks for your password once). `build-app.sh` uses it automatically.

## Usage
- Hold right ⌥ for at least 0.25 s and talk. The mic stays open 300 ms after release, so the last
  syllable isn't clipped.
- Right ⌥ plus another key (e.g. ⌥L for @) still works as a normal shortcut and cancels the dictation.
- "um" is only treated as a filler in English, because it's a real German word ("um zehn Uhr").

## How it works
```
Flow.app (Swift, menu bar)                    asr/server.py (Python sidecar)
 HotkeyMonitor  CGEventTap, right ⌥
 AudioCapture   AVAudioEngine → 16 kHz Int16 ──▶ Unix socket ──▶ Nemotron cache-aware streaming
 OverlayPanel   SwiftUI + Liquid Glass        ◀── JSON partials/final + language tag
 FillerFilter   regex cleanup
 TextInserter   pasteboard swap + ⌘V
 SidecarManager spawns `uv run server.py`, restarts on crash
```
- Audio is cut into 320 ms chunks (`--lookahead 3`); each takes ~26 ms on an M5 Pro (≈ 10× real time).
  The final text arrives ~100 ms after the mic closes. `--lookahead 6` / `13` give 560 ms / 1.12 s
  chunks, which are slightly more accurate but slower to display.
- `--language de-DE` pins the language instead of `auto`.
- The socket protocol is documented in `asr/server.py`; the app talks to
  `~/Library/Application Support/Flow/asr.sock` and reuses a server you started by hand.
- The app starts the sidecar with `HF_HUB_OFFLINE=1`, so run `bench.py` once to cache the model.
  Sidecar log: `~/Library/Logs/Flow-asr.log`.

## Development
| Command | What it does |
|---|---|
| `cd asr && uv run bench.py ../samples/*.wav` | Real-time factor, per-chunk compute, transcripts |
| `cd asr && uv run server.py --socket /tmp/t.sock`, then `uv run smoke.py ../samples/de.wav --socket /tmp/t.sock` | Stream a WAV through the server at speaking pace |
| `build/Flow.app/Contents/MacOS/Flow --selftest` | Filler-filter test cases |
| `build/Flow.app/Contents/MacOS/Flow --demo` | Loop a fake dictation through the HUD (design work, no mic) |
| `swift scripts/make-icon.swift app/Resources/AppIcon.icns` | Regenerate the app icon |

`samples/` holds two clips made with macOS `say` (voices Anna and Samantha).

## Model license
The Nemotron weights are downloaded from Hugging Face at setup and are not part of this repository.
They are licensed by NVIDIA under the [OpenMDW-1.1](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) license.
