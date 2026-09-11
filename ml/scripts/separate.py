#!/usr/bin/env python3
"""Separate an mp3 into stems (vocals/drums/bass/guitar/piano/other) using Meta's
htdemucs_6s pretrained model, saving the results as WAV files under ml/output/.

Usage:
    python scripts/separate.py --input test-assets/sample.mp3
    python scripts/separate.py --input /absolute/path/to/song.mp3 --device cpu
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

MODEL = "htdemucs_6s"
STEMS = ["vocals", "drums", "bass", "guitar", "piano", "other"]

ML_ROOT = Path(__file__).resolve().parent.parent


def resolve_input_path(raw: str) -> Path:
    candidate = Path(raw)
    if candidate.is_absolute() and candidate.exists():
        return candidate
    for base in (Path.cwd(), ML_ROOT):
        resolved = (base / candidate).resolve()
        if resolved.exists():
            return resolved
    return candidate  # let the caller report the not-found error with this path


def main() -> None:
    parser = argparse.ArgumentParser(description="Separate an mp3 into stems using htdemucs_6s.")
    parser.add_argument("--input", required=True, help="Path to the input mp3 file")
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output root directory (default: ml/output)",
    )
    parser.add_argument(
        "--device",
        default=None,
        help="Force a torch device (e.g. cpu, mps, cuda). Default: let demucs auto-pick.",
    )
    args = parser.parse_args()

    input_path = resolve_input_path(args.input)
    if not input_path.exists():
        print(f"[separate] 입력 파일을 찾을 수 없습니다: {input_path}", file=sys.stderr)
        sys.exit(1)

    output_root = Path(args.output_dir).resolve() if args.output_dir else ML_ROOT / "output"
    output_root.mkdir(parents=True, exist_ok=True)

    cmd = [sys.executable, "-m", "demucs", "-n", MODEL, "--out", str(output_root)]
    if args.device:
        cmd += ["-d", args.device]
    cmd.append(str(input_path))

    print(f"[separate] model={MODEL}")
    print(f"[separate] input={input_path}")
    print(f"[separate] output_root={output_root}")
    print(f"[separate] running: {' '.join(cmd)}\n")

    start = time.time()
    result = subprocess.run(cmd)
    elapsed = time.time() - start

    if result.returncode != 0:
        print(f"\n[separate] demucs exited with code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)

    track_dir = output_root / MODEL / input_path.stem
    print(f"\n[separate] 완료 — 처리 시간: {elapsed:.1f}s")
    print(f"[separate] 결과 폴더: {track_dir}\n")

    all_present = True
    for stem in STEMS:
        stem_path = track_dir / f"{stem}.wav"
        if stem_path.exists():
            size_kb = stem_path.stat().st_size / 1024
            print(f"  [ok]      {stem}.wav  ({size_kb:,.0f} KB)")
        else:
            all_present = False
            print(f"  [MISSING] {stem}.wav")

    if not all_present:
        print("\n[separate] 일부 stem 파일이 생성되지 않았습니다.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
