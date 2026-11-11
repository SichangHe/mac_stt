# mac-stt

On-device speech-to-text for Apple Silicon. Bind one command to a key: press once to record, press again to get the text on your clipboard.

## install

```sh
curl -fsSL https://raw.githubusercontent.com/SichangHe/mac_stt/main/install.sh | sh
```

The script downloads the latest release, checks its SHA-256, installs `~/.local/bin/mac-stt`, then downloads and verifies the models (about 2.7 GB) and warms Core ML's cache. It needs an Apple Silicon Mac on macOS 14 or newer and no `sudo`. See [requirements](#requirements).

## use

1. Bind `~/.local/bin/mac-stt toggle` to a key in any hotkey tool (Shortcuts, skhd, Raycast, Hammerspoon, BetterTouchTool).
2. First press: starts recording (a background `mac-stt serve` starts on demand and keeps the models warm). macOS asks once for microphone access.
3. Second press: stops, transcribes the tail, copies the text to the clipboard, and prints it.

Other commands:

```sh
mac-stt record                 # one take in this terminal; Control-C finishes; partials on stderr
mac-stt record --input a.wav   # same pipeline fed from a file at real-time pace
mac-stt transcribe a.m4a b.wav # files, concurrently
mac-stt serve --diarize --no-clipboard   # server options: speaker labels, keep clipboard untouched
mac-stt status | stop | quit
```

Common options: `--diarize` (speaker labels), `--no-clipboard`, `-o FILE`, `--language en` (default: detect), `--model 1.7b|0.6b`.

## how it works

- Model: Qwen3-ASR 1.7B (Alibaba Qwen team, Apache-2.0), in a Core ML conversion by Raymond Chin pinned by commit. See [docs/model-choice.md](docs/model-choice.md) for the leaderboard evidence and the risks of that choice.
- Capture never waits for inference. The capture callback copies buffers into a bounded queue; one consumer resamples to 16 kHz and appends to a session. Overflow fails loudly instead of dropping audio.
- Streaming: the session cuts audio into segments at a pause (after 8 s) or at the quietest point before 30 s, and transcribes each segment in the background while you keep talking. When you stop, only the last segment remains, so the wait after you stop does not grow with total speech length.
- Partial text appears about every 1.5 s from the current unfinished segment.
- A new take can start while the previous one is still being transcribed.
- Speakers (`--diarize`): FluidAudio's diarizer runs in 10 s chunks during recording. A segment with one speaker is labeled directly; a segment with a speaker change is re-transcribed per speaker turn.
- Compute: the audio encoder is configured for CPU and Neural Engine, the int8 decoder for CPU and GPU (Core ML state holds the KV cache). This is a configuration. Neural Engine and GPU placement were not observed; see [docs/evidence.md](docs/evidence.md).

## requirements

- Apple Silicon Mac, macOS 14 or newer. The engine depends on the macOS version (`MAC_STT_BACKEND=coreml|mlx` overrides):
  - macOS 26 or newer: Core ML (`raymondchins/qwen3-asr-*-coreml`). On macOS 26.7 it loaded in seconds.
  - macOS 14 and 15: MLX on the GPU (`mlx-community/Qwen3-ASR-*-8bit`). Core ML's stateful decoder needs macOS 15, and on a hosted macOS 15.8 runner its first compile did not finish in 7 minutes.
  - macOS 14 is untested on real hardware: GitHub has no hosted macOS 14 Apple Silicon runners. The MLX path was tested on hosted macOS 15 runners, and the binary's minimum OS is 14.0.
- About 3 GB of disk for models, stored in the standard Hugging Face hub cache so other apps can share them: `$HF_HUB_CACHE`, else `$HF_HOME/hub`, else `~/.cache/huggingface/hub`, as `models--raymondchins--qwen3-asr-<size>-coreml/{blobs,snapshots/<commit>,refs}`. An existing copy of the pinned commit is reused; missing or mismatched files are fetched and SHA-256 checked. (FluidAudio's diarizer models, used only with `--diarize`, are stored by FluidAudio itself.)

## measured results

See [docs/evidence.md](docs/evidence.md). Everything there came from GitHub-hosted virtual Macs, which have no physical microphone and may not expose the Neural Engine or a real GPU; absolute speed there is not representative of a physical Mac.

## development

```sh
swift build -c release && swift test
scripts/e2e out-dir     # end-to-end run on Apple Silicon macOS (downloads models)
```

Code is in `Sources/MacSTTCore` (`Qwen3/` holds the model pipeline). Third-party provenance: [docs/provenance.md](docs/provenance.md).

## license

[UPL-1.0](LICENSE). The models have their own licenses; see [docs/provenance.md](docs/provenance.md).
