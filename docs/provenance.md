# provenance

- Qwen3-ASR (Alibaba Qwen team): Apache-2.0. https://huggingface.co/Qwen/Qwen3-ASR-1.7B, https://arxiv.org/abs/2601.21337
- Core ML conversion `raymondchins/qwen3-asr-1.7b-coreml`, pinned at commit `09e2ce5602d570e9ffc97e45fb0d9c6dad33bafa` (0.6B: `d77134842e78a651cc01ab50bd8b39c2549f1737`). Apache-2.0; weights are Qwen's, not retrained; converted by Raymond Chin for Speakey. The downloader verifies each file's SHA-256 against the Hugging Face LFS digest. The runtime pipeline in `Sources/MacSTTCore/Qwen3` was written from that model card's description; no Speakey code was used.
- FluidAudio v0.15.6 (Apache-2.0), Swift package dependency, used for speaker diarization and audio resampling. Its diarizer models download at runtime.
- Test audio: LibriSpeech (CC BY 4.0), see `tests/data/README.md`; AMI Meeting Corpus ES2004a (CC BY 4.0, Carletta 2006), downloaded by the diarization check and not stored in this repository.
- The repository has no license file yet; that choice belongs to the owner.
