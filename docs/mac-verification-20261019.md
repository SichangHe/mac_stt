# Mac verification, 2026-10-19
(authored by agents unless marked 🧑)

- result
  - release build and real transcription completed on a hosted Apple Silicon Mac with Swift 6.3.3
  - file and streaming pipelines distinguish the long AMI speaker A and C passages
  - short B/D turns merge into one identity; some words remain `unknown`
  - this sample demonstrates speaker separation, with errors; it does not establish general transcription or speaker attribution accuracy
- implementation
  - commit `1fce75f35e99de3e8cb2fbc5aa6e13f9c10f828a`
    - run feature acceptance on `macos-26` to exercise the current toolchain
    - run unit tests on both `macos-15` and `macos-26` to retain older-system coverage
  - application code and FluidAudio `0.15.6` dependency unchanged
  - retain the independent on-device Mac pipeline; no server dependency is needed for this verification
- commands and runs
  - `git push origin main` triggered both workflows for that commit
  - [tests](https://github.com/SichangHe/mac_stt/actions/runs/39219437895)
    - command: `scripts/check`
    - GitHub reports `"conclusion":"success"` for both `swift (macos-15)` and `swift (macos-26)`
  - [real model features](https://github.com/SichangHe/mac_stt/actions/runs/39219437990)
    - command: `scripts/ci-acceptance ci-evidence`
    - GitHub reports `"conclusion":"success"`
    - [artifact](https://github.com/SichangHe/mac_stt/actions/runs/39219437990/artifacts/12171746609): `mac-stt-macos-arm64-39219437990`
      - digest: `sha256:457bde793be22e70f501a5d976fa9f9ad11c116364c9f068f45211bb0a7be099`
      - full logs and model hashes expire after seven days; key evidence is quoted below
  - retrieve full evidence while retained
    - `gh run download 39219437990 --dir ci-evidence-download`
    - `gh run view 39219437990 --log`
    - `gh run view 39219437895 --log`
- host and release build
  - artifact `system.txt`, exact output
    ```text
    ProductVersion:		26.6.2
    BuildVersion:		25G83
    VirtualMac2,1
    Apple M2 Pro (Virtual)
    swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)
    Target: arm64-apple-macosx26.0
    ```
  - command: `swift build -c release`
  - artifact `build.txt`, final output
    ```text
    [13/14] Linking mac-stt
    Build complete! (112.98s)
    ```
  - artifact `mac-stt.sha256`
    ```text
    bcc5b24943f78a2f484a101e30a4652e92c7326bfb8a48544a5b4a9c1a7fffa7  .build/release/mac-stt
    ```
- input and reference
  - AMI Consortium, AMI Meeting Corpus, `ES2004a.Mix-Headset`, seconds 300–390
    - [source recording](https://huggingface.co/datasets/FluidInference/ami-corpus-mirror/resolve/main/sdm/ES2004a.Mix-Headset.wav)
    - source SHA256: `3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f`
    - extracted WAV SHA256: `55238c1d2fdb90acd0ae44da3337b1377f5c719eb9bf9a48f4239dbfe0d63cd1`
    - adaptation: 90-second WAV excerpt; transcripts quoted below
    - [CC BY 4.0 license](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml)
    - citation: Carletta, J. (2006), Announcing the AMI Meeting Corpus, ELRA Newsletter 11(1), 3–5
  - [AMI manual annotations 1.6.2](https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip)
    - archive SHA256: `b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d`
    - independently inspect `words/ES2004a.{A,B,C,D}.words.xml`
    - reference timestamps below subtract 300 seconds from original word times
    - reference words joined with spaces; original punctuation retained
    - A, 24.13–51.47 seconds, excerpt: “It's your best friend and your you can talk to a dog , it can be your best friend”
    - C, 71.43–75.29 seconds: “And also , my drawing skill isn't that great so , yeah .”
    - B, 50.01–51.09 seconds: “Okay , thank you .”
    - D, 56.51–62.14 seconds: “Please , please leave me a space at the bottom , I'm little , you can get to the top , with standing on a chair .”
- file transcription
  - command: `.build/release/mac-stt transcribe "$diarization_audio" --diarize --compute ane --no-clipboard`
    - `diarization_audio` is the extracted WAV described above
  - artifact `runs/tdt-v3-diarized.txt`, exact excerpts
    ```text
    [00:13.12–00:13.52] unknown: It's
    [00:23.84–00:37.20] 1: It's your best friend in your you can talk to a dog, it can be a best friend, it doesn't discriminate between you based on what you are. Second it's loyal. And third thing, it's got
    [00:50.00–00:51.20] 2: Okay. Thank you.
    [00:56.48–00:58.24] 2: Please please leave me a space at the bottom,
    [01:11.60–01:15.52] 3: also my drawing skill isn't that great. Well as you can see the quality of
    [01:19.92–01:24.24] 3: I'm gonna have to change what it was originally gonna be because that looks like a beak now.
    ```
- streaming transcription from a file
  - command: `.build/release/mac-stt record --input "$diarization_audio" --diarize --compute ane --no-clipboard`
  - artifact `runs/unified-diarized.txt`, exact excerpts
    ```text
    [00:06.72–00:09.84] unknown: A kind of dog? Yep
    [00:24.48–00:50.32] 1: it's your best friend in your you can talk to a dog, it can be your best friend, it doesn't discriminate between you, based on what you are, second it's loyal and third thing, it's got intuition means dogs can some sometimes make out between a thief and a person, so basically these are the three unique features I think belong to a dog.
    [00:50.40–00:51.44] 2: Okay, thank you,
    [00:56.80–00:58.16] 2: please please leave me a space at the
    [01:11.84–01:15.36] 3: and also my drawing skill, isn't that great? Well as you can see the quality
    [01:20.16–01:24.40] 3: now I'm gonna have to change what it w was originally gonna be because that looks like a beak now,
    ```
  - artifact `checks/unified-partials.txt` has 84 distinct partials, including “A kind of dog” and “A kind of dog?  Yep it's actually sitting”
- boundaries
  - the reference has four speakers; both outputs emit three non-unknown identities
  - matching long A/C passages supports observed separation; B/D merging and cross-speaker text within some lines limit correctness
  - no error rate or broad reliability claim follows from this one excerpt
  - file input exercises streaming inference, not a physical microphone
  - both ANE status files report `UNSUPPORTED on this hosted runner`
    - `--compute ane` and placement reports do not prove observed Neural Engine execution
- independent review
  - context-free reviewer `/root/reviewer`, 2026-10-19
    - inspected workflow diff, both CI conclusions and commit identities, raw host/build/transcript evidence, AMI reference, and this record
    - conclusion: “Independent review accepts the delegated Mac goal for this observed sample. No blocking findings.”
    - scope: “Both raw transcripts assign AMI speaker A’s dog passage to identity `1` and speaker C’s drawing passage to `3`. The evidence document correctly retains B/D merging, unknown spans, and cross-speaker errors. It makes no unsupported accuracy, physical microphone, or observed ANE claim.”
