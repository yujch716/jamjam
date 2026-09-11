#!/usr/bin/env python3
"""Convert the STFT/ISTFT-free core of htdemucs_6s (HTDemucsCore, see htdemucs_split.py)
to Core ML (.mlpackage).

Unlike the earlier full-model attempt (scripts/convert_to_coreml.py), this graph has no
complex-number ops at all — STFT/ISTFT and the complex<->real conversions around them are
excluded (they run in plain PyTorch / will run in Swift+Accelerate later, see Pre/Post in
htdemucs_split.py). This script checks whether that's enough for coremltools to succeed,
and if not, logs exactly which op still blocks it.

Usage:
    python scripts/convert_core_to_coreml.py
"""
import sys
import time
import traceback
from pathlib import Path

ML_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ML_ROOT / "scripts"))


def main() -> None:
    output_dir = ML_ROOT / "output" / "CoreMLModels"
    output_dir.mkdir(parents=True, exist_ok=True)
    mlpackage_path = output_dir / "htdemucs_6s_core.mlpackage"

    print("[convert-core] importing torch / demucs / coremltools ...")
    import torch
    import coremltools as ct
    from demucs.pretrained import get_model
    import htdemucs_split as split

    print(f"[convert-core] torch={torch.__version__} coremltools={ct.__version__}")

    # torch's nn.MultiheadAttention (used by some of the cross-transformer's dense,
    # non-sparse attention layers) takes a fused-kernel "fast path" in eval mode that
    # traces to the single ATen op `_native_multi_head_attention` — coremltools 9.0's
    # torch frontend has no converter for that op. Disabling the fast path forces the
    # decomposed eager implementation (linear projections + matmul + softmax), which is
    # made of ops coremltools already supports.
    if hasattr(torch.backends, "mha"):
        torch.backends.mha.set_fastpath_enabled(False)
        print("[convert-core] disabled torch MHA fast path (forces decomposed attention "
              "ops instead of the fused _native_multi_head_attention op)")

    print("[convert-core] loading htdemucs_6s ...")
    bag = get_model("htdemucs_6s")
    model = bag.models[0]
    model.eval()
    core = split.HTDemucsCore(model)
    core.eval()

    training_length = int(model.segment * model.samplerate)
    mix = torch.randn(1, model.audio_channels, training_length) * 0.1

    print("[convert-core] running Pre stage (STFT + magnitude, plain PyTorch) ...")
    mag, mix_padded, length, length_pre_pad, training_length_out = split.pre_process(model, mix)
    print(f"[convert-core] mag shape: {tuple(mag.shape)}  mix_padded shape: {tuple(mix_padded.shape)}")

    # --- Step 1: sanity check the plain PyTorch Core forward pass ---
    print("\n[convert-core] === Step 1: plain PyTorch Core forward pass (sanity check) ===")
    t0 = time.time()
    with torch.no_grad():
        try:
            m_out, xt_out = core(mag, mix_padded)
            print(f"[convert-core] OK — m shape {tuple(m_out.shape)}, xt shape {tuple(xt_out.shape)}, "
                  f"in {time.time() - t0:.2f}s")
        except Exception:
            print("[convert-core] FAILED even in plain PyTorch — not a Core ML-specific issue:")
            traceback.print_exc()
            sys.exit(1)

    # --- Step 2: torch.jit.trace ---
    print("\n[convert-core] === Step 2: torch.jit.trace ===")
    t0 = time.time()
    try:
        with torch.no_grad():
            traced = torch.jit.trace(core, (mag, mix_padded), strict=False)
        print(f"[convert-core] torch.jit.trace OK in {time.time() - t0:.2f}s")
    except Exception:
        print("[convert-core] torch.jit.trace FAILED:")
        traceback.print_exc()
        sys.exit(2)

    # --- Step 3: coremltools.convert ---
    print("\n[convert-core] === Step 3: coremltools.convert (no complex ops expected in "
          "this graph — this is the test) ===")
    t0 = time.time()
    try:
        # compute_precision=FLOAT32: coremltools' mlprogram default (FLOAT16) causes a
        # large numerical blowup here (max abs diff ~109 on the `m` output, vs ~1e-6 with
        # FLOAT32) — almost certainly fp16 overflow/underflow inside the many LayerNorm/
        # softmax ops in the cross-transformer's ~12 attention layers. FLOAT32 costs
        # roughly 2x model size and is likely slower on the Neural Engine, but is what
        # makes the output numerically trustworthy; a mixed-precision pass (fp16 for
        # convs, fp32 just for norm/softmax) is a possible follow-up optimization once
        # this baseline is verified.
        mlmodel = ct.convert(
            traced,
            inputs=[
                ct.TensorType(name="mag", shape=mag.shape),
                ct.TensorType(name="mix", shape=mix_padded.shape),
            ],
            outputs=[
                ct.TensorType(name="m"),
                ct.TensorType(name="xt"),
            ],
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.iOS17,
            compute_precision=ct.precision.FLOAT32,
        )
        print(f"[convert-core] coremltools.convert OK in {time.time() - t0:.2f}s")
    except Exception as exc:
        print(f"[convert-core] coremltools.convert FAILED after {time.time() - t0:.2f}s")
        print(f"[convert-core] exception type: {type(exc).__module__}.{type(exc).__name__}")
        print("[convert-core] full traceback:")
        traceback.print_exc()
        sys.exit(3)

    # --- Step 4: save ---
    print(f"\n[convert-core] === Step 4: saving to {mlpackage_path} ===")
    mlmodel.save(str(mlpackage_path))
    size_bytes = sum(f.stat().st_size for f in mlpackage_path.rglob("*") if f.is_file())
    print(f"[convert-core] saved. total .mlpackage size: {size_bytes / (1024 * 1024):.1f} MB")

    # --- Step 5: reload + predict sanity check (+ compare vs plain PyTorch Core output) ---
    print("\n[convert-core] === Step 5: reload + predict sanity check ===")
    import numpy as np
    t0 = time.time()
    reloaded = ct.models.MLModel(str(mlpackage_path))
    load_time = time.time() - t0
    t0 = time.time()
    result = reloaded.predict({
        "mag": mag.numpy().astype(np.float32),
        "mix": mix_padded.numpy().astype(np.float32),
    })
    predict_time = time.time() - t0
    print(f"[convert-core] load: {load_time:.2f}s, predict: {predict_time:.2f}s, "
          f"output keys: {list(result.keys())}")

    for key, torch_ref in (("m", m_out), ("xt", xt_out)):
        coreml_out = result[key]
        diff = np.abs(coreml_out - torch_ref.numpy())
        print(f"[convert-core] {key}: max abs diff vs PyTorch = {diff.max():.3e}, "
              f"mean abs diff = {diff.mean():.3e}")

    print(f"\n[convert-core] output keys/shapes: "
          f"{[(k, v.shape) for k, v in result.items()]}")
    print("[convert-core] DONE.")


if __name__ == "__main__":
    main()
