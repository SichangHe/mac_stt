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

## acceptance run

```sh
mac-stt doctor
mac-stt profile-model /actual/TDT-v3/Encoder.mlmodelc --compute ane
scripts/measure-ane acceptance.wav tdt-v3-ane-power.txt > acceptance.txt
```

Use the actual compiled bundle path from FluidAudio's model cache. This file command measures multilingual TDT v3.

The live model is separate. After one `record` run downloads it, profile the bundle named `parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc`, then measure the same model during capture:

```sh
mac-stt profile-model /actual/parakeet_unified_encoder_streaming_70_7_1_int8.mlmodelc --compute ane
scripts/measure-ane --record unified-ane-power.txt > live-acceptance.txt
```

Speak for at least 20 seconds, then press Control-C.

Compare against `--compute cpu` using the same warmed model and audio. Record wall time and ANE samples for both. ANE activity in the first run and an idle baseline in the CPU-only run is stronger evidence than timing alone.

## boundaries

Apple describes `cpuAndNeuralEngine` as the option that can “use both the CPU and neural engine, but not the GPU.” It does not guarantee either device for every operation: https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine

FluidAudio's model-specific profiler reports that Parakeet TDT v3's large encoder can be planned mostly for ANE while preprocessing and recurrent decoding remain on CPU. Its published numbers are evidence for its measured M5 and model revision, not for a different Mac: https://github.com/FluidInference/FluidAudio/blob/v0.15.6/Documentation/ANE_Profiler.md
