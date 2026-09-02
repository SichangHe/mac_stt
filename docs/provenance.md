# provenance

## Source-1348

The project was requested as a new `mac_stt` repository. The request named `zachswift615/speak2` as a possible fork or code reference and asked for Apple Neural Engine support, Parakeet, diarization, streaming capture, nonblocking finalization, clipboard output, and a fine-tuning resource assessment.

The hosted acceptance workflow downloads `ES2004a.Mix-Headset.wav` from FluidAudio's AMI corpus mirror, verifies SHA-256 `3e2560b19bee6952c7c7ce041b0f1ea8a7ea9468044c4eea79d2a2c67e24ab0f`, and derives a 90-second excerpt covering seconds 300 through 390. The AMI Consortium releases the AMI Meeting Corpus under [CC BY 4.0](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml); the requested citation is Carletta, J. (2006), “Announcing the AMI Meeting Corpus,” ELRA Newsletter 11(1), 3–5. Neither the source audio nor the excerpt is uploaded as a workflow artifact.

## Bootstrap decision

Create an original repository rather than fork or copy `speak2`.

At upstream commit `19901d2e9cc757d562aa604f46a8f1749cb3902e`, GitHub reports no license and the checked tree has no license file. Public visibility does not grant permission to copy, modify, or redistribute code. Until the upstream author supplies a compatible license, treat its implementation as read-only design reference and do not copy source or history.

## References

- `https://github.com/zachswift615/speak2`, observed at commit `19901d2e9cc757d562aa604f46a8f1749cb3902e`
- `https://github.com/FluidInference/FluidAudio`, dependency tag `v0.15.6`, commit `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`, authenticated 2026-09-01 as Apache-2.0 from its repository license and GitHub license metadata
- `https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml`, downloaded at runtime through FluidAudio; its model card declares CC-BY-4.0 metadata and says it is derived from `nvidia/parakeet-tdt-0.6b-v3`
- `https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3`, upstream model card and training artifact
- `https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml`, live English model; its card declares CC-BY-4.0 and identifies `nvidia/parakeet-tdt-0.6b-v2` as the base model

FluidAudio is linked as a Swift Package dependency; none of its source is vendored. The model-placement walker uses public Core ML APIs and was implemented locally. FluidAudio's profiler documentation was consulted to validate the claim boundary and measurement method.

## Hardware claim boundary

Core ML or an `all` compute-unit setting permits system scheduling but does not alone prove that a workload ran on the Apple Neural Engine. Acceptance needs measured runtime evidence and must distinguish Neural Engine, GPU, and CPU execution. Unsupported layers and model conversions may fall back to GPU or CPU.

## Ownership

Bootstrap-owned paths are `README.md` and `docs/provenance.md`. No upstream source code or Git history is included.
