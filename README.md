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
