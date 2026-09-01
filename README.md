# mac_stt

Private macOS speech-to-text CLI research and implementation workspace.

Initial goals:

- Apple Silicon acceleration with measured compute-unit evidence; do not claim Apple Neural Engine execution from API configuration alone
- Parakeet transcription
- speaker diarization
- live transcription while recording
- background finalization so a new recording is not blocked by prior processing
- transcription copied to the clipboard by default
- evidence-based assessment of fine-tuning resources before committing to training work

The implementation is original. Upstream projects may inform design only when their licenses permit the intended reuse. See [docs/provenance.md](docs/provenance.md).
