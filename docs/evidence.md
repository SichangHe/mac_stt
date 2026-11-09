# evidence

All runs are on GitHub-hosted virtual Macs (`Apple M1 (Virtual)` or M2 Pro (Virtual), macOS 26.7.2, 7.5 GB RAM). They have no physical microphone. Neural Engine and GPU use were not observed (`powermetrics` is unavailable). Run speed varied by more than 10x between runners with identical labels, so the latency figures below describe those VMs, not a real Mac.

Test speech: LibriSpeech dev-clean, speaker 1272, utterances joined with 0.8 s gaps (`tests/data`). WER is word error rate after lowercasing and dropping punctuation (`scripts/wavtool.py`).

## accuracy and latency versus speech length

Run https://github.com/SichangHe/mac_stt/actions/runs/42688419358 (the fastest runner we drew). File mode processes the whole file as fast as it can. Stream mode feeds the same audio at real-time pace through `mac-stt record --input`, then measures the time from the last sample to the final text.

```
speech    file proc   WER     stream finalize
  6.4 s     3.74 s    5.88 %    3.01 s
 25.3 s     9.90 s    3.39 %    2.22 s
 36.0 s    10.60 s    2.41 %    4.99 s
 66.2 s    25.55 s    5.30 %    3.72 s
123.9 s    52.55 s    4.09 %    2.28 s
242.3 s    96.15 s    3.33 %    1.14 s
```

Stream WER equals file WER at every length (same segmenter and model). The wait after stopping stayed between 1.1 and 5.0 s as speech grew 38-fold, which is the intended behavior: only the last segment is left when recording stops.

On slower runners decoding took 0.6 to 1.9 s per token (https://github.com/SichangHe/mac_stt/actions/runs/42700505286: `trace: audio 6.4s mel 3 ms encode 4454 ms (1 windows) decode 27904 ms (25 tokens, 1116.2 ms/token)`), and transcription fell behind real time, so finalize took 39 to 168 s. The model card reports 4.9 ms per decoder step on an M5 Max. Which of the two a real Mac resembles is unmeasured here.

## features

Run https://github.com/SichangHe/mac_stt/actions/runs/42708325859 (`scripts/e2e-features`):

```
clipboard opt-out: PASS (sentinel unchanged)
clipboard default: PASS: Mr. Quilter is the apostle of the middle classes, ...
toggle 1: recording
toggle 2 returned after 86.3 s with: Mr. Quilter is the apostle of the middle classes, ...
toggle clipboard: PASS
toggle WER: 3.39 %
overlap: second take starts while the first finalizes: recording
[22:11:09] speech_seconds=25.3 finalize_seconds=68.070
[22:11:09] recording started
```

The toggle test starts the real `serve` daemon through `mac-stt toggle`, feeds a WAV file through the capture path in place of the microphone (`MAC_STT_FAKE_MIC`), and stops it with a second `toggle`. The "recording started" at 22:11:09 is the second take beginning in the same second the first take's result was written, while the first take's transcription had run for 68 s of finalize; the first take's output arrived afterwards. Not observed: a real microphone, a real key press, macOS microphone permission, the start and stop sounds.

Diarization, run https://github.com/SichangHe/mac_stt/actions/runs/42710742189 (AMI ES2004a, seconds 300 to 390): 3 distinct speakers in both modes.

```
diarization (file): 3 distinct speakers
[00:08.00–00:50.00] 1: Yep, it's actually sitting. So sorry, it's sitting. ...
[00:50.00–01:01.90] 2: Okay. Thank you. Thank you. Okay. Sorry. Please, please leave me a space at the bottom. ...
[01:01.90–01:14.67] 3: Since you guys have chosen the ones I wanted to do, has to go for something a bit random. ...
diarization (streaming): 3 distinct speakers
```

The first 8 s ("A kind of dog.") is labeled `unknown`. There is no WER or diarization error rate for this clip.

## install

Run https://github.com/SichangHe/mac_stt/actions/runs/42692984387 (macos-26, no checkout, the public script):

```
mac-stt-macos-arm64.tar.gz: OK
installed /Users/runner/.local/bin/mac-stt
[..] loading encoder (ane)
[..] decoder loaded
setup complete: models ready in 105.9 s, first inference 37.05 s
install wall time: 144 s
...
WER: 2.41 %
```

## macOS 15

On `macos-15` (15.8.2) the decoder's first Core ML load did not finish in 7 minutes under `cpu`, `gpu` or `ane` (https://github.com/SichangHe/mac_stt/actions/runs/42683370247; a stack sample shows it in `bnns::GraphCompile`). On macOS 26.7.2 it loaded in 7 to 75 s. The program therefore requires macOS 26.
