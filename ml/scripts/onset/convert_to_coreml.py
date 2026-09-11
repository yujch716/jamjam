#!/usr/bin/env python3
"""Convert the trained OnsetCNN to Core ML (.mlpackage).

Unlike htdemucs_6s, this model has no complex-number ops (pure Conv2d/BatchNorm/
Linear/ReLU/MaxPool/Sigmoid) — expected to convert cleanly. This script converts,
saves, then verifies load+predict against the original PyTorch model to confirm
numerical correctness, exactly like the demucs conversion check.

Usage:
    python scripts/onset/convert_to_coreml.py
"""
import sys
import time
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ML_ROOT = Path(__file__).resolve().parent.parent.parent
CHECKPOINT_PATH = ML_ROOT / "output" / "onset_model" / "onset_cnn_best.pt"
OUTPUT_DIR = ML_ROOT / "output" / "CoreMLModels"

# Supports a variable number of windows per call (1 up to MAX_BATCH) so the app can
# run the whole file's frames through in one call instead of one at a time.
MAX_BATCH = 8192


def main():
    print("[convert] importing torch / coremltools ...")
    import torch
    import numpy as np
    import coremltools as ct
    from model import OnsetCNN, count_params
    from melspec import N_MELS, CONTEXT_FRAMES

    print(f"[convert] torch={torch.__version__} coremltools={ct.__version__}")

    print(f"[convert] loading checkpoint {CHECKPOINT_PATH}")
    model = OnsetCNN()
    model.load_state_dict(torch.load(CHECKPOINT_PATH, map_location="cpu"))
    model.eval()
    print(f"[convert] params: {count_params(model):,}")

    # Core ML output should be a probability, not a raw logit — wrap with sigmoid.
    class OnsetCNNWithSigmoid(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return torch.sigmoid(self.inner(x))

    wrapped = OnsetCNNWithSigmoid(model)
    wrapped.eval()

    example_input = torch.randn(4, N_MELS, CONTEXT_FRAMES)

    print("\n[convert] === Step 1: plain PyTorch forward pass (sanity check) ===")
    with torch.no_grad():
        try:
            ref_out = wrapped(example_input)
            print(f"[convert] OK — output shape {tuple(ref_out.shape)}")
        except Exception:
            print("[convert] FAILED in plain PyTorch:")
            traceback.print_exc()
            sys.exit(1)

    print("\n[convert] === Step 2: torch.jit.trace ===")
    try:
        with torch.no_grad():
            traced = torch.jit.trace(wrapped, example_input)
        print("[convert] torch.jit.trace OK")
    except Exception:
        print("[convert] torch.jit.trace FAILED:")
        traceback.print_exc()
        sys.exit(2)

    print("\n[convert] === Step 3: coremltools.convert ===")
    t0 = time.time()
    try:
        batch_dim = ct.RangeDim(1, MAX_BATCH, default=1)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="mel_window", shape=(batch_dim, N_MELS, CONTEXT_FRAMES))],
            outputs=[ct.TensorType(name="onset_probability")],
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.iOS17,
            compute_precision=ct.precision.FLOAT32,
        )
        print(f"[convert] coremltools.convert OK in {time.time() - t0:.2f}s")
    except Exception as exc:
        print(f"[convert] coremltools.convert FAILED after {time.time() - t0:.2f}s")
        print(f"[convert] exception type: {type(exc).__module__}.{type(exc).__name__}")
        traceback.print_exc()
        sys.exit(3)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    mlpackage_path = OUTPUT_DIR / "onset_cnn.mlpackage"
    print(f"\n[convert] === Step 4: saving to {mlpackage_path} ===")
    mlmodel.save(str(mlpackage_path))
    size_bytes = sum(f.stat().st_size for f in mlpackage_path.rglob("*") if f.is_file())
    print(f"[convert] saved. total .mlpackage size: {size_bytes / (1024 * 1024):.2f} MB")

    print("\n[convert] === Step 5: reload + predict sanity check ===")
    reloaded = ct.models.MLModel(str(mlpackage_path))
    t0 = time.time()
    result = reloaded.predict({"mel_window": example_input.numpy().astype(np.float32)})
    predict_time = time.time() - t0
    out_key = list(result.keys())[0]
    coreml_out = result[out_key]
    diff = np.abs(coreml_out - ref_out.numpy())
    print(f"[convert] predict OK in {predict_time:.3f}s, output '{out_key}' shape {coreml_out.shape}")
    print(f"[convert] max abs diff vs PyTorch: {diff.max():.3e}, mean abs diff: {diff.mean():.3e}")

    # timing over a realistic-size batch (~one file's worth of frames)
    big_batch = torch.randn(2000, N_MELS, CONTEXT_FRAMES).numpy().astype(np.float32)
    t0 = time.time()
    reloaded.predict({"mel_window": big_batch})
    big_time = time.time() - t0
    print(f"[convert] 2000-window batch predict: {big_time:.3f}s "
          f"({big_time / 2000 * 1000:.3f}ms/window)")

    print("\n[convert] DONE.")


if __name__ == "__main__":
    main()
