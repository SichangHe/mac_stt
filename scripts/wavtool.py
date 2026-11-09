"""Helpers for the end-to-end test: prefix WAV by utterances, and word error rate.

  wavtool.py prefix WAV TSV MIN_SECONDS OUT_WAV OUT_REF   utterances until at least MIN_SECONDS
  wavtool.py wer REF_FILE HYP_FILE                         prints WER as a percentage
"""
import re
import sys
import wave


def normalize(text):
    text = text.lower().replace("-", " ")
    text = re.sub(r"[^a-z0-9' ]", " ", text)
    return text.split()


def prefix(wav_path, tsv_path, minimum, out_wav, out_ref):
    rows = [line.rstrip("\n").split("\t") for line in open(tsv_path)][1:]
    chosen = []
    for row in rows:
        chosen.append(row)
        if float(row[2]) >= minimum:
            break
    source = wave.open(wav_path)
    rate = source.getframerate()
    end = int((float(chosen[-1][2]) + 0.5) * rate)
    frames = source.readframes(min(end, source.getnframes()))
    out = wave.open(out_wav, "wb")
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(rate)
    out.writeframes(frames)
    out.close()
    open(out_ref, "w").write(" ".join(r[3] for r in chosen) + "\n")
    print("%.1f" % (len(frames) / 2 / rate))


def wer(ref_path, hyp_path):
    ref = normalize(open(ref_path).read())
    hyp = normalize(open(hyp_path).read())
    row = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        new = [i]
        for j, h in enumerate(hyp, 1):
            new.append(min(row[j] + 1, new[j - 1] + 1, row[j - 1] + (r != h)))
        row = new
    print("%.2f" % (100.0 * row[-1] / max(1, len(ref))))


if __name__ == "__main__":
    if sys.argv[1] == "prefix":
        prefix(sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5], sys.argv[6])
    elif sys.argv[1] == "wer":
        wer(sys.argv[2], sys.argv[3])
    else:
        sys.exit("unknown subcommand")
