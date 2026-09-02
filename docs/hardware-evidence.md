# hardware evidence

## claim levels

- configured
  - `--compute ane` sets Core ML to CPU plus Neural Engine
  - this excludes GPU but permits CPU fallback
- planned
  - `profile-model` loads `MLComputePlan`
  - it counts each operation's preferred CPU, GPU, or Neural Engine device
  - this proves the scheduler plan for that compiled model and Mac
- observed
  - `powermetrics` samples ANE power during real transcription
  - activity above the idle baseline, aligned with inference, is runtime evidence
  - retain the Mac model, macOS version, model files, command, and raw samples

## complete acceptance run

```sh
scripts/acceptance multiminute-two-speaker.wav acceptance-$(date -u +%Y%m%dT%H%M%SZ)
```

Run this in a normal Terminal on an Apple Silicon Mac. The input must contain enough clear speech from two speakers that both file jobs remain active while the microphone starts; use several minutes on a fast Mac. After an automatic model warm-up, the script asks for three 30-second live passages: comparable clean ANE and CPU passages, then a two-speaker overlap passage. Grant microphone access if macOS asks.

The retained directory contains host, input, command, runner, binary, and runtime-model identity; compiled model placement; real diarized file and microphone results; default and opt-out clipboard checks; two file jobs overlapping the microphone run; and clean raw ANE-versus-CPU power samples for TDT v3 and Unified. It is deliberately labeled a candidate: inspect the raw power comparison and changing live partials before declaring acceptance. The overlap trace is never used for ANE attribution because concurrent workloads would confound it.

## focused measurement

Measure multilingual TDT v3 with the same warmed model and audio:

```sh
scripts/measure-ane --compute ane acceptance.wav tdt-ane-power.txt > tdt-ane.txt
scripts/measure-ane --compute cpu acceptance.wav tdt-cpu-power.txt > tdt-cpu.txt
```

Measure Unified during two comparable microphone passages:

```sh
scripts/measure-ane --compute ane --record unified-ane-power.txt > unified-ane.txt
scripts/measure-ane --compute cpu --record unified-cpu-power.txt > unified-cpu.txt
```

Speak, then press Enter to stop each live run.

Compare ANE against CPU using the same warmed model and audio or comparable live passages. ANE activity in the first run and an idle baseline in the CPU-only run is stronger evidence than timing alone.

## boundaries

Apple describes `cpuAndNeuralEngine` as the option that can “use both the CPU and neural engine, but not the GPU.” It does not guarantee either device for every operation: https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine

FluidAudio's model-specific profiler reports that Parakeet TDT v3's large encoder can be planned mostly for ANE while preprocessing and recurrent decoding remain on CPU. Its published numbers are evidence for its measured M5 and model revision, not for a different Mac: https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Documentation/ANE_Profiler.md
