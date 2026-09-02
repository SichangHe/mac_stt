# mac-stt

An original macOS CLI for private, on-device Parakeet transcription. It supports live microphone partials, concurrent file jobs, optional speaker diarization, and clipboard output by default.

## requirements

- Apple Silicon Mac
- macOS 14 or newer; macOS 14.4 or newer for model placement reports
- Xcode 16 or a Swift 6 toolchain
- about 1 GB free for the first model download; diarization downloads additional models
- microphone permission for `record`

## install

```sh
swift build -c release
sudo install .build/release/mac-stt /usr/local/bin/mac-stt
```

The first inference downloads model assets from Hugging Face. Later runs use FluidAudio's local cache.

## use

```sh
# English live partial text on stderr; final result to stdout and clipboard
mac-stt record

# exercise the Unified streaming pipeline from a finite file
mac-stt record --input speech.wav --diarize --no-clipboard

# add speaker labels to the final result
mac-stt record --diarize

# process files concurrently and combine their results on the clipboard
mac-stt transcribe interview.m4a memo.wav --diarize

# keep the clipboard unchanged
mac-stt transcribe memo.wav --no-clipboard -o memo.txt

# inspect Core ML's preferred device plan for compiled model bundles
mac-stt profile-model /path/to/Encoder.mlmodelc --compute ane
```

The default `--compute ane` means `.cpuAndNeuralEngine`: CPU and ANE are eligible and GPU is excluded. That setting is not proof of ANE execution. `profile-model` reports planned placement per operation. For observed runtime evidence, run `sudo powermetrics --samplers ane_power -i 200` while transcribing and retain its output with the CLI result. See [hardware evidence](docs/hardware-evidence.md).

## behavior

- `record` copies audio buffers into an asynchronous stream before inference, so capture does not wait on Core ML
- the live model is English Parakeet Unified 0.6B, derived from Parakeet TDT v2; file transcription uses multilingual TDT v3
- partial text changes while recording; Control-C flushes the final text
- capture buffers at most about 5.5 seconds at 48 kHz; overload fails explicitly instead of losing audio or growing memory without bound
- `transcribe FILE...` creates an independent manager task per input and preserves argument order in the combined output
- `--diarize` assigns ASR words to overlapping speaker spans by timestamp; live diarization consumes bounded 10-second chunks
- stdout always receives the final result; the clipboard does too unless `--no-clipboard` is present

The compact code map is [docs/design.md](docs/design.md). Fine-tuning costs and the recommended experiment are in [docs/fine-tuning.md](docs/fine-tuning.md). Third-party provenance is recorded in [docs/provenance.md](docs/provenance.md).

## acceptance

On an Apple Silicon Mac, `scripts/acceptance TWO_SPEAKER_AUDIO BUNDLE_DIR` runs and retains the real feature and ANE-versus-CPU evidence needed for acceptance. The bundle remains a candidate until a human checks the raw power samples and changing live partials. See [hardware evidence](docs/hardware-evidence.md).

The `macOS feature evidence` GitHub workflow runs real TDT v3, Unified, diarization, partial, clipboard, placement, and overlap probes on a hosted arm64 Mac. Diarization uses a checksummed 90-second excerpt from the CC BY 4.0 AMI Meeting Corpus; provenance and the derived transcript are retained, but the audio is not. A green run means only those automatable features passed. File input is not microphone evidence. `powermetrics` results are retained as observed samples or explicitly warned and marked unsupported; configuration and placement never count as observed ANE execution.
