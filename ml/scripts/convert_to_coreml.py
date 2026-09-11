#!/usr/bin/env python3
"""Attempt to convert the htdemucs_6s PyTorch model to Core ML (.mlpackage).

This is a feasibility check, not a production converter: htdemucs_6s is a Hybrid
Transformer Demucs model that calls `torch.stft`/`torch.istft` (with complex tensors)
internally for its spectrogram branch. Core ML's MIL IR has no complex-number dtype, so
this is expected to fail at the trace-to-MIL conversion step — the point of this script is
to confirm that precisely, and log exactly which op/line it dies on, rather than assume.

Usage:
    python scripts/convert_to_coreml.py
    python scripts/convert_to_coreml.py --segment-seconds 2.0
"""
import argparse
import sys
import time
import traceback
from pathlib import Path

ML_ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser(description="Try converting htdemucs_6s to Core ML.")
    parser.add_argument(
        "--segment-seconds",
        type=float,
        default=None,
        help="Length of the dummy input waveform used for tracing (seconds). Default: the "
        "model's own training segment length — see the module docstring note on "
        "`length_pre_pad` for why a shorter input hits a tracing dead end.",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Where to save the .mlpackage on success (default: ml/output/CoreMLModels)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir).resolve() if args.output_dir else ML_ROOT / "output" / "CoreMLModels"
    output_dir.mkdir(parents=True, exist_ok=True)
    mlpackage_path = output_dir / "htdemucs_6s.mlpackage"

    print("[convert] importing torch / demucs / coremltools ...")
    import torch
    import coremltools as ct
    from demucs.pretrained import get_model

    print(f"[convert] torch={torch.__version__} coremltools={ct.__version__}")

    print("[convert] loading htdemucs_6s ...")
    bag = get_model("htdemucs_6s")
    model = bag.models[0]
    model.eval()

    if args.segment_seconds is not None:
        n_samples = int(args.segment_seconds * model.samplerate)
    else:
        # Match HTDemucs.forward's own `training_length` exactly (it uses `Fraction` math
        # internally — recomputing that way, rather than segment_seconds * samplerate in
        # float, avoids an off-by-one from float rounding). Feeding anything *shorter* than
        # this trips the `length_pre_pad` short-input padding branch (see module docstring),
        # which traces into a shape derived from `mix.shape[-1]` that coremltools' `aten::Int`
        # handling can't convert — using the natural training length sidesteps that branch
        # entirely rather than working around the converter bug.
        n_samples = int(model.segment * model.samplerate)
    example_input = torch.randn(1, model.audio_channels, n_samples)
    print(f"[convert] example input shape: {tuple(example_input.shape)} "
          f"({n_samples / model.samplerate:.2f}s @ {model.samplerate}Hz)")

    # --- Step 1: sanity check the plain PyTorch forward pass still works ---
    print("\n[convert] === Step 1: plain PyTorch forward pass (sanity check) ===")
    t0 = time.time()
    with torch.no_grad():
        try:
            out = model(example_input)
            print(f"[convert] OK — output shape {tuple(out.shape)} in {time.time() - t0:.2f}s")
        except Exception:
            print("[convert] FAILED even in plain PyTorch — not a Core ML-specific issue:")
            traceback.print_exc()
            sys.exit(1)

    # --- Step 2: torch.jit.trace ---
    print("\n[convert] === Step 2: torch.jit.trace ===")
    t0 = time.time()
    try:
        with torch.no_grad():
            traced = torch.jit.trace(model, example_input, strict=False)
        print(f"[convert] torch.jit.trace OK in {time.time() - t0:.2f}s")
    except Exception:
        print("[convert] torch.jit.trace FAILED:")
        traceback.print_exc()
        sys.exit(2)

    # --- Step 3: coremltools.convert ---
    print("\n[convert] === Step 3: coremltools.convert (this is where complex-tensor ops "
          "from torch.stft/istft are expected to fail) ===")
    t0 = time.time()
    try:
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="mix", shape=example_input.shape)],
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.iOS17,
        )
        print(f"[convert] coremltools.convert OK in {time.time() - t0:.2f}s")
    except Exception as exc:
        print(f"[convert] coremltools.convert FAILED after {time.time() - t0:.2f}s")
        print(f"[convert] exception type: {type(exc).__module__}.{type(exc).__name__}")
        print("[convert] full traceback:")
        traceback.print_exc()
        print(
            "\n[convert] DIAGNOSIS: if the traceback above mentions `stft`, `istft`, "
            "`view_as_real`, `view_as_complex`, or a complex dtype, this confirms the "
            "known limitation — Core ML's MIL IR has no complex-number support, and "
            "HTDemucs's spectrogram branch (demucs/spec.py: spectro()/ispectro()) calls "
            "torch.stft(..., return_complex=True) / torch.istft(...) directly."
        )
        sys.exit(3)

    # --- Step 4: save ---
    print(f"\n[convert] === Step 4: saving to {mlpackage_path} ===")
    mlmodel.save(str(mlpackage_path))
    print("[convert] saved.")

    # --- Step 5: quick reload + predict sanity check ---
    print("\n[convert] === Step 5: reload + predict sanity check ===")
    t0 = time.time()
    reloaded = ct.models.MLModel(str(mlpackage_path))
    import numpy as np
    result = reloaded.predict({"mix": example_input.numpy().astype(np.float32)})
    print(f"[convert] predict OK in {time.time() - t0:.2f}s, output keys: {list(result.keys())}")


if __name__ == "__main__":
    main()
