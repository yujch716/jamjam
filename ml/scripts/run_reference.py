#!/usr/bin/env python3
"""Generate Python-side reference outputs for comparing against the Swift/Accelerate +
Core ML pipeline, using the exact same input audio segment (see README's "Swift/Core ML
pipeline verification" section).

Writes, under --output-dir:
  - mag_reference.npy   : Pre stage output (STFT + magnitude packing), for isolating
                          STFT correctness before touching Core ML/ISTFT at all.
  - mix_padded_reference.npy : Pre stage's (possibly zero-padded) raw waveform, the
                          other Core ML input.
  - <source>.wav (x6)   : final Pre->Core->Post separated stems (float32 WAV), to
                          compare against Swift's output stems.

Usage:
    python scripts/run_reference.py --input test-assets/test_segment.wav
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

ML_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ML_ROOT / "scripts"))
import htdemucs_split as split  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="WAV file, exactly training_length samples")
    parser.add_argument("--output-dir", default=None)
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.is_absolute():
        candidate = ML_ROOT / input_path
        input_path = candidate if candidate.exists() else Path.cwd() / input_path

    output_dir = Path(args.output_dir).resolve() if args.output_dir else ML_ROOT / "output" / "swift_compare" / "python_reference"
    output_dir.mkdir(parents=True, exist_ok=True)

    print("[ref] loading htdemucs_6s ...")
    from demucs.pretrained import get_model
    bag = get_model("htdemucs_6s")
    model = bag.models[0]
    model.eval()
    core = split.HTDemucsCore(model)
    core.eval()

    print(f"[ref] loading audio: {input_path}")
    data, sr = sf.read(str(input_path))  # [N, C] float64
    assert sr == model.samplerate, f"expected {model.samplerate}Hz, got {sr}Hz"
    mix = torch.from_numpy(data.T).float().unsqueeze(0)  # [1, C, N]
    print(f"[ref] mix shape: {tuple(mix.shape)}")

    with torch.no_grad():
        mag, mix_padded, length, length_pre_pad, training_length = split.pre_process(model, mix)
        print(f"[ref] mag shape: {tuple(mag.shape)}  (Pre stage output — compare this "
              f"directly against Swift's STFT output first)")
        np.save(output_dir / "mag_reference.npy", mag.numpy())
        np.save(output_dir / "mix_padded_reference.npy", mix_padded.numpy())

        m, xt = core(mag, mix_padded)
        np.save(output_dir / "m_reference.npy", m.numpy())
        np.save(output_dir / "xt_reference.npy", xt.numpy())
        out = split.post_process(model, m, xt, length, length_pre_pad, training_length)
        print(f"[ref] final output shape: {tuple(out.shape)}")

    sources = model.sources
    out_np = out[0].numpy()  # [S, C, L]
    for i, name in enumerate(sources):
        wav_path = output_dir / f"{name}.wav"
        sf.write(str(wav_path), out_np[i].T, sr, subtype="FLOAT")
        print(f"[ref] wrote {wav_path.name}  peak={np.abs(out_np[i]).max():.4f}")

    print(f"\n[ref] done. Reference files in: {output_dir}")


if __name__ == "__main__":
    main()
