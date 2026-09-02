# fine-tuning assessment

## conclusion

Fine-tuning is feasible, but the practical supported path is a separate NVIDIA GPU training run followed by Core ML conversion. Do not try to train the packaged Core ML files. Start only after a held-out domain test proves that vocabulary boosting or prompt-side correction is insufficient.

## facts

- Parakeet TDT v3 has 0.6 billion parameters and the model card identifies NeMo, 16 kHz mono input, 25 European languages, CC-BY-4.0 metadata, and published benchmark WERs
  - https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- NeMo says “Fine-tuning is recommended” for domain-specific data, accents, acoustic environments, and new-language adaptation; it supplies `speech_to_text_finetune.py` and documents direct initialization from a Hugging Face model
  - its current guide recommends 50 to 100 epochs for domain adaptation and learning rates from `1e-4` to `1e-5`
  - https://github.com/NVIDIA-NeMo/NeMo/blob/main/docs/source/asr/fine_tuning.rst
- the current NeMo configuration uses one or more GPUs, a default per-GPU batch size of 16, 20 second maximum clips, AdamW, and validation WER checkpoint selection
  - https://github.com/NVIDIA-NeMo/NeMo/blob/main/examples/asr/conf/asr_finetune/speech_to_text_finetune.yaml
- FluidAudio publishes the conversion source used to turn the trained checkpoint into Core ML assets
  - https://github.com/FluidInference/mobius/tree/main/models/stt/parakeet-tdt-v3-0.6b/coreml

## estimates

These are planning estimates, not vendor guarantees. Actual memory depends on clip lengths, batch size, precision, optimizer, activation checkpointing, and frozen layers.

- full-model AdamW training
  - rough lower bound before activations: 0.6B parameters times about 16 bytes for weights, gradients, and optimizer state, or about 9.6 GB
  - plan for a 24 GB NVIDIA GPU as the practical single-GPU starting point
  - 16 GB may work only after lowering batch size and using memory-saving settings
- parameter-efficient or encoder-frozen adaptation
  - materially lowers trainable-state memory
  - still requires empirical accuracy and conversion validation because the deployed graph must match the changed checkpoint
- data
  - first pilot: 10 to 20 hours of accurately transcribed target-domain audio
  - hold out speakers and recording conditions; never select on the final test set
  - include a general-domain regression set to detect catastrophic forgetting
- time
  - run a 100 to 500 utterance overfit check first
  - then budget hours to a few days per pilot on one modern 24 GB GPU
  - measure throughput after the first 200 steps before estimating the full run

## recommended gate

- baseline the unmodified model on at least 1,000 representative utterances
- classify errors into vocabulary, acoustic, accent, language, and diarization errors
- try FluidAudio custom-vocabulary rescoring for vocabulary-only failures
- fine-tune only if acoustic or domain errors remain material
- compare standalone WER with identical normalization and decoding
- convert the winning checkpoint to Core ML
- rerun accuracy, placement-plan, runtime-power, latency, and memory acceptance tests

Fine-tuning ASR does not fine-tune diarization. Speaker diarization needs its own labeled speaker-time data, loss, evaluation metric, and conversion work.

The assessment above targets the multilingual TDT v3 model used by `transcribe`. `record` uses English Parakeet Unified, whose model card identifies TDT v2 as its base and says its encoder was trained for multiple streaming contexts. A v3 checkpoint cannot simply replace those live assets. Fine-tuning live Unified requires preserving or reproducing its streaming-context training and exporting the exact `70_7_1` graph; treat that as a separate experiment: https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml
