# model choice

Source: the Open ASR Leaderboard Space, `hf-audio/open_asr_leaderboard`, version 1.15.0 (06-11-2026), read from its live Gradio config on 2026-11-09. Ranking is by average WER over AMI-Cleaned, Earnings22, Gigaspeech, SPGISpeech, URGENT24, Voice Arena Monsoon, Voxpopuli and two private sets.

Open-weight rows (average WER, RTFx):

- rank 9 `nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B`: 6.13, 472.62
- rank 10 `Qwen/Qwen3-ASR-1.7B-hf`: 6.15, 835.62
- rank 25 `nvidia/parakeet-tdt-0.6b-v2`: 6.93, 6148.32
- rank 31 `nvidia/parakeet-tdt-0.6b-v3`: 7.04, 6321.90
- rank 33 `Qwen/Qwen3-ASR-0.6B-hf`: 7.07, 749.52

Ranks 1 to 8 and 11, 12 are closed commercial APIs (zoom, OtterAI, microsoft, p99lab, elevenlabs, modulate, reson8, sophea, assemblyai, smallestai).

Choice: Qwen3-ASR-1.7B, Apache-2.0. It is the best Alibaba model on the board and within 0.02 WER of the best open-weight entry. That entry is a 30B-parameter model, which cannot run efficiently on a laptop. Against the previous Parakeet TDT v2, the board's average WER falls from 6.93 to 6.15 (11% relative).

Risks, stated plainly:

- The board measures averages over mixed datasets. Our own check is LibriSpeech read speech (docs/evidence.md), which is easy and says little about meetings.
- Qwen3-ASR has no official Core ML build. This project uses a one-week-old community conversion by one author, pinned by commit and checksum. Its card reports about 3% of words differing from the original bf16 weights, mostly from fp16 on the Neural Engine.
- Official streaming inference exists only with vLLM (CUDA). Streaming here is segment-based, done by this project.
- No word timestamps. Diarization assigns whole segments or speaker turns, not words.
- The decoder KV cache holds 1024 rows, which limits one segment to about 30 s.
