# terms

- compute policy
  - Core ML devices allowed by configuration
- placement plan
  - Core ML's preferred device for each model operation
  - evidence of scheduling intent, not runtime activity
- observed execution
  - device activity measured while inference is running
- live partial
  - provisional transcript emitted before recording ends
- final transcript
  - transcript after queued audio and decoder state are flushed
- diarization
  - assigning anonymous speaker identifiers to time spans
- job
  - one input and its independent mutable inference state
