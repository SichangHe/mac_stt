# provenance

## Source-1348

The project was requested as a new `mac_stt` repository. The request named `zachswift615/speak2` as a possible fork or code reference and asked for Apple Neural Engine support, Parakeet, diarization, streaming capture, nonblocking finalization, clipboard output, and a fine-tuning resource assessment.

## Bootstrap decision

Create an original repository rather than fork or copy `speak2`.

At upstream commit `19901d2e9cc757d562aa604f46a8f1749cb3902e`, GitHub reports no license and the checked tree has no license file. Public visibility does not grant permission to copy, modify, or redistribute code. Until the upstream author supplies a compatible license, treat its implementation as read-only design reference and do not copy source or history.

## References

- `https://github.com/zachswift615/speak2`, observed at commit `19901d2e9cc757d562aa604f46a8f1749cb3902e`
- `https://github.com/FluidInference/FluidAudio`, referenced by `speak2` for Parakeet on Apple Silicon; authenticate its exact revision and license before dependency adoption

## Hardware claim boundary

Core ML or an `all` compute-unit setting permits system scheduling but does not alone prove that a workload ran on the Apple Neural Engine. Acceptance needs measured runtime evidence and must distinguish Neural Engine, GPU, and CPU execution. Unsupported layers and model conversions may fall back to GPU or CPU.

## Ownership

Bootstrap-owned paths are `README.md` and `docs/provenance.md`. No upstream source code or Git history is included.
