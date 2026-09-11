#!/usr/bin/env python3
"""Verify that Pre -> HTDemucsCore -> Post produces (numerically) the same output as
HTDemucs's own unmodified forward(). See htdemucs_split.py for the stage boundary.

Usage:
    python scripts/verify_split.py                              # random noise input
    python scripts/verify_split.py --input test-assets/song.mp3 # real audio input
"""
import argparse
import sys
import time
from pathlib import Path

import torch

ML_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ML_ROOT / "scripts"))
import htdemucs_split as split  # noqa: E402


def load_real_audio(path: Path, model):
    from demucs.audio import AudioFile
    training_length = int(model.segment * model.samplerate)
    audio = AudioFile(str(path)).read(
        seek_time=30.0,  # skip likely-silent intro
        duration=training_length / model.samplerate,
        channels=model.audio_channels,
        samplerate=model.samplerate,
    )
    if audio.shape[-1] < training_length:
        audio = torch.nn.functional.pad(audio, (0, training_length - audio.shape[-1]))
    return audio[None]  # add batch dim -> [1, C, L]


def report(name: str, ref: torch.Tensor, out: torch.Tensor):
    diff = (ref - out).abs()
    max_abs = diff.max().item()
    mse = (diff ** 2).mean().item()
    ref_scale = ref.abs().mean().item()
    print(f"[verify:{name}] output shape: {tuple(out.shape)}")
    print(f"[verify:{name}] max abs diff:  {max_abs:.3e}")
    print(f"[verify:{name}] MSE:           {mse:.3e}")
    print(f"[verify:{name}] ref |x| mean:  {ref_scale:.3e}  (scale reference)")
    verdict = "NEGLIGIBLE (bit-identical or float-noise level)" if max_abs < 1e-4 else "NOT negligible — investigate"
    print(f"[verify:{name}] verdict: {verdict}\n")
    return max_abs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default=None, help="optional mp3/wav to use instead of random noise")
    args = parser.parse_args()

    print("[verify] loading htdemucs_6s ...")
    from demucs.pretrained import get_model
    bag = get_model("htdemucs_6s")
    model = bag.models[0]
    model.eval()
    core = split.HTDemucsCore(model)
    core.eval()

    training_length = int(model.segment * model.samplerate)
    worst = 0.0

    print("\n=== Test 1: random noise input ===")
    torch.manual_seed(0)
    mix = torch.randn(1, model.audio_channels, training_length) * 0.1
    with torch.no_grad():
        t0 = time.time()
        ref = model(mix.clone())
        t_ref = time.time() - t0
        t0 = time.time()
        out = split.split_forward(model, core, mix.clone())
        t_split = time.time() - t0
    print(f"[verify:noise] reference forward: {t_ref:.2f}s, split forward: {t_split:.2f}s")
    worst = max(worst, report("noise", ref, out))

    if args.input:
        input_path = Path(args.input)
        if not input_path.is_absolute():
            candidate = ML_ROOT / input_path
            input_path = candidate if candidate.exists() else Path.cwd() / input_path
        print(f"=== Test 2: real audio input ({input_path.name}) ===")
        mix = load_real_audio(input_path, model)
        with torch.no_grad():
            ref = model(mix.clone())
            out = split.split_forward(model, core, mix.clone())
        worst = max(worst, report("real-audio", ref, out))

    if worst == 0.0:
        print("[verify] RESULT: bit-for-bit identical on all tests. The Pre/Core/Post "
              "split introduces zero numerical difference vs. the original model.")
    elif worst < 1e-4:
        print(f"[verify] RESULT: negligible difference (max abs diff {worst:.3e}), "
              "within normal floating-point reordering noise.")
    else:
        print(f"[verify] RESULT: WARNING — max abs diff {worst:.3e} is non-negligible.")
        sys.exit(1)


if __name__ == "__main__":
    main()
