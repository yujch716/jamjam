# jamjam ML pipeline (Python, separate from the Swift app)

On-device AI chart-generation pipeline work happens here, fully separate from the
Xcode/Swift project. Nothing here ships in the app directly — this is where the
source-separation (and later, onset-detection) models get evaluated before any
Core ML conversion work begins.

## Setup

```bash
cd ml
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Python 3.11 was chosen deliberately (not the system's newer 3.14) for the widest
compatibility with demucs' pinned dependencies.

## Source separation (htdemucs_6s)

```bash
source venv/bin/activate
python scripts/separate.py --input test-assets/<song>.mp3
```

Outputs `vocals.wav`, `drums.wav`, `bass.wav`, `guitar.wav`, `piano.wav`, `other.wav`
under `output/htdemucs_6s/<song-name>/`. `output/` and `test-assets/` are gitignored
(generated/local audio, not committed).

### First test run (2026-09-10)

- Input: a ~2:44 (163.8s) mp3
- Device: MPS (Apple M1 Pro GPU) — demucs auto-selects it over CPU when available
- Processing time: 30.2s → **≈5.4x faster than real-time**
- Model weights: ~52MB (`htdemucs_6s`, downloaded once and cached by huggingface_hub)
- All 6 stems produced successfully, ~28MB each (uncompressed WAV)

This is on a laptop-class GPU via MPS, not the iPad's Neural Engine via Core ML — useful
as a rough sanity check that the model itself is fast enough to be viable, but not a
direct prediction of on-device (Core ML) performance.

Known limitation (per Meta's own docs): guitar/piano separation quality is
noticeably behind vocals/drums/bass/other.

## Onset-detection CNN (2026-09-11)

Lightweight CNN that classifies whether a mel-spectrogram frame is a note onset —
this is what turns a separated instrument stem into "when do the notes fall" for chart
generation. Trained on guitar/drums/bass/vocals (**piano excluded from training** per
scope decision — the game keeps piano as a playable instrument, but its onset
detection will reuse this same generalized model rather than get a dedicated
dataset/retrain).

### Datasets (all CC-BY-4.0 — commercial use OK with attribution)

| Instrument | Dataset | Files used | Onsets | License |
|---|---|---|---|---|
| Guitar | GuitarSet (Xi, Bittner et al.) | 360 | 62,476 | CC-BY-4.0 |
| Drums | Groove MIDI Dataset (Google Magenta) | 1,090 | 347,597 | CC-BY-4.0 |
| Bass | BabySlakh (MERL / Interactive Audio Lab) | 22 | 9,082 | CC-BY-4.0 |
| Vocals | VocalSet + Annotated-VocalSet (Wilkins/Seetharaman/Wahl/Pardo) | 2,683 | 29,829 | CC-BY-4.0 |

Onset ground truth: GuitarSet from JAMS `note_midi` annotations (every string);
GMD/BabySlakh from MIDI note-on events; VocalSet from Annotated-VocalSet's per-note
"Sound" segments (excluding "Rest"/"Transition" segments). Split 85/15 train/val **by
file** (3,532 train / 623 val) to avoid leakage. Note: Annotated-VocalSet ships 4
redundant annotation passes ("extended 1-4") over the identical 2,688 files — only
pass 1 is used; using all 4 would have quietly 4x'd and leaked vocals data across the
split.

Cached to `ml/output/onset_dataset/{train,val}.npz` (+ `_meta.json`): 6.8M frames
(14.0% positive) train, 1.08M frames (11.5% positive) val — log-mel spectrograms,
22.05kHz/80 mels/10ms hop, frame-level binary labels (±1 frame tolerance around each
onset time).

### Model: `OnsetCNN` (`ml/scripts/onset/model.py`)

Schlüter & Böck (2014)-style small CNN: 3x (Conv2d+BatchNorm+ReLU[+MaxPool]) over an
80-mel x 15-frame context window, then FC(64)+dropout+FC(1) sigmoid. **260,097
parameters, ~1.0MB as float32** — deliberately tiny for later Core ML conversion
(pure Conv2d/BatchNorm/Linear/ReLU/MaxPool/Sigmoid, no attention or custom ops, so no
complex-number-style blocker is expected this time).

### Training

PyTorch MPS backend (Apple M1 Pro), weighted BCE loss (`pos_weight=6.16`, matching the
14% positive rate) + a `WeightedRandomSampler` that equalizes each instrument's
contribution per epoch (GMD alone provided far more raw frames than GuitarSet/BabySlakh
would otherwise justify).

**Interrupted once**: the Mac lost power (battery drained overnight — confirmed via
`last reboot`/no panic log/no clean-shutdown log entries — not a spec or MPS
limitation; the job itself was light, ~55-75% CPU, ~4-5GB RAM) around epoch 9. Resumed
from the epoch-9 checkpoint with `caffeinate -s` wrapping the process to prevent it
recurring. Training curve (frame-level, threshold 0.5):

| epoch | train_loss | val_F1 | | epoch | train_loss | val_F1 |
|---|---|---|---|---|---|---|
| 1 | 0.347 | 0.757 | | 11 | 0.266 | 0.744 |
| 2 | 0.306 | 0.747 | | 12 | 0.265 | **0.768 (best)** |
| 3 | 0.293 | 0.742 | | 13 | 0.264 | 0.743 |
| 4 | 0.287 | 0.766 | | 14 | 0.263 | 0.761 |
| 5 | 0.281 | 0.746 | | 15 | 0.262 | 0.756 |
| 6 | 0.278 | 0.757 | | 16 | 0.260 | 0.751 |
| 7 | 0.274 | 0.751 | | 17 | 0.260 | 0.763 |
| 8 | 0.271 | 0.739 | | 18 | 0.259 | 0.747 |
| 9 | 0.269 | 0.773 | | 19 | 0.258 | 0.755 |
| 10 | 0.268 | 0.764 | | | | |

**Stopped early at epoch 19** (checkpoint from epoch 12, best val F1) — train_loss was
still inching down but val F1 had plateaued/oscillated in the 0.74-0.77 band for 7+
epochs with no new best, a mild overfitting signal, so further epochs weren't worth the
~10.5min/epoch cost. Checkpoint: `ml/output/onset_model/onset_cnn_best.pt`.

### CNN vs. spectral-flux baseline (`compare_baseline.py`)

Event-level onset F1 with the standard ±50ms MIREX/mir_eval tolerance window (this is a
different, stricter metric than the frame-level table above — greedy one-to-one onset
matching, not per-frame classification):

| instrument | method | precision | recall | F1 |
|---|---|---|---|---|
| bass | baseline | 0.818 | 0.861 | 0.839 |
| bass | **CNN** | 0.958 | 0.806 | **0.875** |
| drums | baseline | 0.997 | 0.509 | 0.674 |
| drums | **CNN** | 0.931 | 0.642 | **0.760** |
| guitar | baseline | 0.663 | 0.514 | 0.579 |
| guitar | **CNN** | 0.819 | 0.523 | **0.639** |
| vocals | baseline | 0.099 | 0.547 | 0.168 |
| vocals | **CNN** | 0.529 | 0.764 | **0.625** |
| **OVERALL** | baseline | 0.522 | 0.530 | 0.526 |
| **OVERALL** | **CNN** | 0.848 | 0.638 | **0.728** |

CNN beats the rule-based baseline on every instrument — biggest win on vocals (the
spectral-flux baseline barely works there, 0.168 F1; the CNN gets 0.625). Overall F1
+0.202 absolute (~38% relative improvement).

Sample visualizations (waveform + log-mel spectrogram with ground-truth onsets in
green, CNN detections as red markers), 2 per instrument, in
`ml/output/onset_figures/`.

### Core ML conversion (2026-09-12) — succeeds on the first try

```bash
python scripts/onset/convert_to_coreml.py
```

As expected, no complex-number blocker this time (pure Conv2d/BatchNorm/Linear/ReLU/
MaxPool/Sigmoid — nothing like htdemucs_6s's STFT problem):

- **Model size**: 1.00 MB (`.mlpackage`, FLOAT32, `ml/output/CoreMLModels/onset_cnn.mlpackage`)
- **Accuracy vs. PyTorch**: max abs diff 2.98e-7 (float32-precision-level, essentially exact)
- **Speed** (Mac, coremltools `.predict()`, compute units auto): 0.169ms/window over a
  2000-window batch. Input accepts a flexible batch size (1 to 8192 windows per call via
  `RangeDim`), so a whole file's frames can be classified in one call rather than one
  window at a time.
- **Extrapolated to a 4-minute song (Mac)**: ~24,048 frames (100.2fps × 240s) × 0.169ms
  ≈ ~4 seconds.

### Real iPad hardware run (2026-09-12) — confirms and beats the Mac numbers

Ran on the paired physical device ("Yujin의 iPad", iPad Air 11" M3), Release build,
`computeUnits = .all`. 200 real val-set windows compared against a PyTorch-generated
reference, plus a 2000-window timing batch (same size as the Mac benchmark):

- **Correctness**: max abs diff 2.03e-6, mean 2.2e-7 vs. PyTorch — matches the Mac
  result, confirms the FP32 model runs correctly on-device.
- **Speed**: 0.0618ms/window (2000-window batch, 0.124s total) — actually **faster
  than the Mac** (0.169ms/window), unlike htdemucs_6s's case where FP32 hurt ANE
  throughput; this model is tiny enough that it's not memory-bandwidth-bound the same
  way.
- **4-minute song, on-device**: **~1.49 seconds** for onset detection across the whole
  song. Combined with the ~19s demucs separation step, the full "mp3 in → separated
  stems + note charts out" pipeline is well within CLAUDE.md's async-processing
  budget.

## Full pipeline integration test (2026-09-12)

`ml/scripts/full_pipeline.py` — the first end-to-end run of "mp3 in → note_chart JSON
per instrument out", entirely in Python, before porting any of this to Swift/Core ML.
Ties together demucs separation + the onset CNN + two pieces of logic that didn't exist
yet:

- **Full-song demucs separation**: the Core-ML-bound `Pre→Core→Post` split
  (`htdemucs_split.py`) only accepts exactly one training-length (7.8s) segment, so
  `full_pipeline.separate_full_song()` chunks the song into 50%-overlapping
  training-length segments and reassembles them with a Hann-window crossfade (COLA at
  50% hop → exact unity-gain overlap-add, the same trick used for the STFT/ISTFT OLA
  earlier) — this is the same segmenting strategy the eventual Swift/Core ML pipeline
  will need for songs longer than one segment. 158.8s test song → 42 chunks → 90.7s to
  separate (Mac, CPU).
- **Peak-picking** (`note_classification.pick_peaks`): turns the onset CNN's per-frame
  probability curve into discrete onset timestamps — local-maximum detection within
  each above-threshold run, plus a minimum-separation merge step (light NMS) so one
  note attack doesn't get double-counted.
- **Tap/hold classification** (`note_classification.classify_notes`): not something the
  onset CNN outputs at all. Measures how long a note's RMS envelope stays above a
  threshold *relative to that note's own peak level* (20% of its local peak, sampled in
  the ~50ms right after onset) — under 0.2s -> tap, over -> hold, with hold `duration`
  capped at whichever comes first, the envelope decaying or the next onset starting.

### Energy pre-filter — kills silence false-positives

Running the full pipeline surfaced a real problem: on near-silent stretches of a stem,
the onset CNN would still fire — most visibly on piano (no dedicated training data,
and htdemucs's piano separation is the known-weakest of the 6 sources, leaving more
separation-noise residue in silence). Fixed with a track-relative energy gate,
`note_classification.compute_silence_mask()`: any frame whose RMS is below **4% of
that stem's own peak RMS** gets its onset probability zeroed before peak-picking,
regardless of what the CNN says. Relative to each stem's own peak, not a fixed dB
level — a stem's overall loudness varies a lot per song/instrument, so an absolute
threshold would misfire. Applied uniformly to all 4 instruments, not as a
piano-specific special case.

Before/after note counts on the full 158.8s test song:

| instrument | before filter | after filter | change |
|---|---|---|---|
| guitar | 562 | 562 | none — no false positives existed |
| drums | 1,096 | 960 | -136 (-12%) |
| bass | 732 | 732 | none |
| piano | 548 | 206 | **-342 (-62%)** |

Guitar and bass were completely unaffected — confirms the filter isn't just
indiscriminately cutting real notes. Piano's ~55s near-silent middle stretch
(60-115s), previously scattered with false onset markers throughout, is now
completely clean; the remaining piano notes line up with the song's actual audible
piano passages (0-10s, ~15-27s, ~43-50s, 145-155s). Drums lost some hits too, but
visibly only in genuinely quiet moments — the busy sections look unchanged.

### Results (full 158.8s test song, `ml/output/full_pipeline/full_decoded/`)

| instrument | total notes | tap | hold | notes/sec |
|---|---|---|---|---|
| guitar | 562 | 285 | 277 | 3.54 |
| drums | 960 | 880 | 80 | 6.05 |
| bass | 732 | 447 | 285 | 4.61 |
| piano | 206 | 156 | 50 | 1.30 |

Per-instrument outputs: `<instrument>_chart.json` (the note_chart itself),
`<instrument>_viz.png` (waveform + log-mel spectrogram with note markers — green=tap,
orange=hold span), `<instrument>_click.wav` (the separated stem with a click sound
overlaid at every note onset, for listening back), `<instrument>_stem.wav` (plain
separated audio, no clicks).

**Guitar/drums/bass**: note markers line up tightly with actual energy transients in
the waveform, correctly silent during instrumental gaps — visually and structurally
sound. **Piano** (generalized from the guitar/drums/bass/vocals-trained model, no
piano-specific data): after the energy pre-filter, no longer produces silence
false-positives, and detects real onsets during the song's actual piano passages —
but this is the least-trained-for instrument (weakest htdemucs separation + zero
piano training data for the onset CNN), so it should be treated as the shakiest of
the four pending a listen-through, not assumed equivalent in quality to the other
three.

`python scripts/full_pipeline.py --input <mp3-or-wav> [--reuse-stems]` —
`--reuse-stems` skips the expensive demucs pass and reloads previously-saved
`<out_dir>/<source>_stem.wav` files, for fast iteration on onset-detection parameters
alone.

## Core ML conversion attempt (2026-09-10) — failed, root cause confirmed

```bash
source venv/bin/activate
python scripts/convert_to_coreml.py
```

**Result: conversion fails, and cannot be made to work by adjusting tool versions.**
Root cause: Core ML's MIL (Model Intermediate Language) type system has **no
complex-number dtype at all** (`fp16/fp32/int8/int16/int32/uint8/uint16/bool` only).
`htdemucs_6s` is a *Hybrid Transformer* Demucs — its spectrogram branch
(`demucs/spec.py: spectro()` / `ispectro()`, called from `HTDemucs._spec()`/`_ispec()`)
calls `torch.stft(..., return_complex=True)` and `torch.istft(...)` directly, producing a
genuine `complex64` tensor mid-graph. The exact failure:

```
ValueError: Op "124" (op_type: slice_by_index) Input x="119" expects tensor or scalar of
dtype from type domain ['fp16', 'fp32', 'int8', 'int16', 'int32', 'uint8', 'uint16', 'bool']
but got tensor[1,2,2049,340,complex64]
```

This is a hard architectural incompatibility, not a bug in a specific coremltools
release — trying other coremltools versions will not fix it.

### Two unrelated bugs found (and fixed) while isolating that root cause

These masked the real error and had to be fixed first before the complex-dtype error
could even be reached:

1. **Short test input trips a different code path.** Feeding a short dummy clip (e.g. 2s)
   instead of the model's natural training length hits demucs's `length_pre_pad`
   short-input padding branch (`htdemucs.py`), whose traced shape (derived from
   `mix.shape[-1]`) hits a separate coremltools `aten::Int` conversion bug. Fixed by using
   the model's own training length (`model.segment * model.samplerate` ≈ 7.8s) as the
   trace input instead of an arbitrary short clip.
2. **numpy 2.x breaks coremltools 9.0's int-cast op.** coremltools calls
   `int(some_ndarray)` on what it assumes is a 0-d array but is actually shape `(1,)`;
   numpy 2.x removed the implicit scalar conversion for that case
   (`TypeError: only 0-dimensional arrays can be converted to Python scalars`). Fixed by
   pinning `numpy<2` (resolved to 1.26.4). Confirmed this pin doesn't break
   `separate.py` (regression-tested, still works, 21.1s for the same test song).

### What this means for the AI pipeline

- No `.mlpackage` was produced, so model size / on-device inference timing / Swift or
  iPad load-and-predict verification could not be performed — there's nothing to load.
- **Version-swapping coremltools won't help** — this isn't a version bug like #2 above,
  it's a missing primitive (complex dtype) in Core ML's IR itself.
- **The real fix, if this path is pursued**: reimplement `_spec`/`_ispec` to avoid
  `torch.stft`/`istft` entirely — replace them with real-valued `Conv1d`/`ConvTranspose1d`
  layers using precomputed (non-learned) DFT-basis weight matrices, producing separate
  real+imaginary tensors instead of one complex tensor. This is a known technique for
  making STFT-based models Core ML-compatible, but is a substantial rework (touches
  `_spec`, `_magnitude`, mask application, and `_ispec`), not a config change.
- **Alternative pretrained models checked — none satisfy both "no complex/STFT ops" and
  "guitar+piano stems"**:
  - Open-Unmix: no STFT-complex issue avoided (still STFT-based) and only ships
    vocals/drums/bass/other — no guitar/piano at all.
  - Spleeter 5-stem: has piano but not guitar, and is also STFT-based internally, so it
    would hit the same Core ML limitation.
  - Older waveform-domain Demucs (v2/v3, non-hybrid): avoids STFT/complex tensors
    entirely, but only supports 4 stems (vocals/drums/bass/other) — no guitar/piano.
  - Conclusion: no drop-in alternative meets the spec's guitar+piano requirement without
    the same complex-tensor blocker. The Conv1d/DFT reimplementation above is the only
    identified path to a Core ML-compatible model with guitar+piano stems.

## STFT/ISTFT-excluded core conversion (2026-09-10) — succeeds

Instead of reimplementing STFT as Conv1d (the plan above), we tried a smaller first
step: keep `torch.stft`/`torch.istft` running in plain PyTorch (soon: Swift+Accelerate
vDSP) **outside** the Core ML graph, and convert only the purely real-valued neural
network in between (encoder/decoder/cross-transformer). See `scripts/htdemucs_split.py`
for the full stage split with exact code-line references into demucs 4.1.0's source.

```bash
source venv/bin/activate
python scripts/verify_split.py                 # numeric equivalence check
python scripts/convert_core_to_coreml.py        # conversion + save + reload/predict
```

### The three stages

- **Pre** (plain PyTorch, not traced): pad `mix` to the training length if needed →
  `model._spec(mix)` (`torch.stft`, complex64) → `model._magnitude(z)` (`view_as_real` +
  reshape, real) → `mag`.
- **Core** (`HTDemucsCore`, what gets converted): takes `(mag, mix_padded)`, runs the
  *exact* body of `HTDemucs.forward()` between `_magnitude` and `_mask`/`_ispec`
  (encoder → freq-embedding → cross-transformer → decoder, both the frequency and time
  branches) verbatim, no complex ops at all. Returns `(m, xt)`, both real.
- **Post** (plain PyTorch, not traced): reassemble `m` into a complex spectrogram
  (inverse of `_magnitude`'s packing) → `model._ispec(...)` (`torch.istft`, real
  waveform) → add the time-branch `xt` → (optionally truncate if the input was
  padded).

### Numeric equivalence (verify_split.py)

Ran the unmodified `model(mix)` and the split `Pre → Core → Post` pipeline on the same
random-noise input (shape `[1, 2, 343980]`, the model's natural 7.8s training length —
real MP3 audio couldn't be tested here because this machine has no `ffmpeg`/`ffprobe`
installed, which demucs' audio loader shells out to; not installed since it's outside
this task's ask). Result:

```
max abs diff: 0.0
MSE:          0.0
```

**Bit-for-bit identical.** This isn't an approximation — Pre/Core/Post is the same
sequence of tensor ops as the original `forward()`, just split across three Python
functions, so there is zero room for numeric drift regardless of input content.

### Core ML conversion (convert_core_to_coreml.py)

**Succeeds** — with one non-obvious fix needed along the way:

1. First attempt failed with `NotImplementedError: PyTorch convert function for op
   '_native_multi_head_attention' not implemented`. Cause: some of the cross-transformer's
   attention layers use plain `torch.nn.MultiheadAttention` (demucs's own sparse-attention
   layers use a hand-written matmul+softmax implementation that's fine, but the dense ones
   inherit torch's standard module), which in eval mode takes a fused "fast path" that
   traces to a single opaque ATen op coremltools 9.0 doesn't implement. Fixed with
   `torch.backends.mha.set_fastpath_enabled(False)` before tracing — forces the decomposed
   eager implementation (linear projections + matmul + softmax), which converts fine.
2. Conversion then succeeded, but with `compute_precision` left at coremltools' mlprogram
   default (FLOAT16), output vs. the PyTorch reference showed a **max abs diff of ~109**
   on the `m` output (whose own values only range up to ~0.46) — a real fp16 numerical
   blowup, not benign rounding, almost certainly fp16 overflow/underflow somewhere across
   the ~12 LayerNorm/softmax ops in the cross-transformer. Fixed by converting with
   `compute_precision=ct.precision.FLOAT32` instead: max abs diff dropped to **~2.1e-6**
   (float32 rounding noise) — numerically trustworthy.

Final result (FLOAT32):
- **Model size**: 146.4 MB (`.mlpackage`, `output/CoreMLModels/htdemucs_6s_core.mlpackage`,
  gitignored) — roughly 2x the 52 MB PyTorch weights, expected for FLOAT16→FLOAT32.
- **Load + reload/predict sanity check**: passes, output vs. PyTorch max abs diff ~2.1e-6.
- **Inference time** (Mac, M1 Pro, `MLModel.predict`, compute units = ALL — CPU+GPU+ANE
  auto-dispatch by the Core ML runtime, no iPad measurement done yet): ~0.29s average per
  7.8s segment (5-run average, after a warmup call). This is the Core-only time — it
  excludes Pre/Post's STFT/ISTFT, which are cheap FFT ops by comparison.
- A possible future optimization (not done): mixed precision — FLOAT16 for the conv/linear
  layers, FLOAT32 only for the LayerNorm/softmax ops that overflowed, to shrink the model
  back toward ~75 MB without reintroducing the blowup. Not attempted since this task's
  goal was "does conversion work at all," not size optimization.

### STFT/ISTFT parameters (must match exactly in the future Swift/Accelerate implementation)

From `demucs/spec.py` (`spectro`/`ispectro`) and `HTDemucs._spec`/`_ispec`
(`demucs/htdemucs.py`), for `htdemucs_6s` specifically (`model.nfft=4096`,
`model.hop_length=1024`, `model.audio_channels=2`, `model.samplerate=44100`):

| Parameter | Value |
|---|---|
| `n_fft` | 4096 |
| `hop_length` | 1024 (= n_fft / 4) |
| `win_length` | 4096 (= n_fft) |
| window | Hann, **periodic** (`torch.hann_window(4096)` default `periodic=True` — NOT the symmetric variant; in vDSP terms this is the `N+1`-point symmetric window truncated to N samples, not `vDSP_hann_window(N, ...)` used directly) |
| `normalized` | `True` — confirmed empirically: STFT output is scaled by exactly `1/sqrt(win_length)` = `1/sqrt(4096)` = `0.015625` relative to the unnormalized STFT. ISTFT must apply the exact inverse (multiply by `sqrt(win_length)` before overlap-add, or equivalent). |
| `center` | `True` (frames centered on `hop_length * i`, standard `center`-mode STFT framing) |
| `pad_mode` | `reflect` |

Extra padding/cropping `HTDemucs._spec`/`_ispec` do around the raw STFT (on top of
`center=True`'s own internal reflect-padding) — required for exact frame-count parity,
not optional:

- **Forward (`_spec`)**: let `hl = hop_length = 1024`. Reflect-pad the input mix by
  `pad = hl // 2 * 3 = 1536` samples on **both** sides (`pad1d(..., mode="reflect")`).
  Let `le = ceil(input_length / hl)`. Run the raw STFT on the padded signal, drop the
  Nyquist bin (`z[..., :-1, :]`, so freq axis goes from `n_fft/2+1=2049` down to
  **2048** bins), then keep only the central `le` time frames: `z[..., 2 : 2 + le]`
  (this crops exactly 2 frames off each end, which are edge artifacts of the extra
  padding). For the model's training-length input (343980 samples), this yields
  `le = 336` frames — matches the traced `mag`/`m` tensor shapes `(B, C*2, 2048, 336)`.
- **Inverse (`_ispec`)**: pad the spectrogram back — one zero-frame at the end along
  the freq axis (`F.pad(z, (0,0,0,1))`, restoring the dropped Nyquist bin as zero) and
  2 zero-frames on each side along the time axis (`F.pad(z, (2,2))`, undoing the
  `[2:2+le]` crop), run ISTFT, then slice out `x[..., pad : pad + length]` where
  `pad = 1536` and `length` is the originally requested output length.

Real/imag channel packing (the exact tensor layout Swift's output must match — see
`htdemucs_split.py`'s module docstring for the derivation from `_magnitude`/`_mask`):
for `audio_channels=2` (stereo), a spectrogram tensor's channel axis is laid out as
`[ch0_real, ch0_imag, ch1_real, ch1_imag]` — i.e. **not** all reals followed by all
imags, but real/imag interleaved in pairs per audio channel. `mag` (Pre's output, fed
into Core ML) and `m` (Core ML's output, fed into Post) use this identical packing;
`m`'s full shape keeps the 6 sources as a separate leading dimension (`[B, S, C*2, Fq, T]`),
not merged into the channel axis.

## Swift/Accelerate STFT + Core ML + ISTFT verification (2026-09-10) — succeeds

Full on-device chain verified: WAV in → vDSP STFT → `htdemucs_6s_core.mlpackage` →
vDSP ISTFT → 6 stem WAVs. Temporary code, isolated from the real app (see
`jamjam/jamjam/MLPipelineTest/` — `HTDemucsSTFT.swift`, `HTDemucsPipelineRunner.swift`,
`MLPipelineTestView.swift` — wired in temporarily via `jamjamApp.swift`; not part of the
real app flow yet). The `.mlpackage` and test audio live under
`MLPipelineTest/Resources/`, gitignored (146MB model, and the test clip is derived from
a copyrighted song).

### Method

1. Decoded a fixed 7.8s clip of the test song to WAV via macOS `afconvert` (avoids
   needing `ffmpeg`, which this Python env doesn't have) — `ml/scripts/run_reference.py`
   and the Swift app both consume this exact same WAV, so any difference in their
   outputs is attributable to the two implementations, not to different input audio.
2. `run_reference.py` runs Python's Pre→Core→Post pipeline on it, saving `mag`/`m`/`xt`
   as `.npy` and the 6 stems as WAV (`ml/output/swift_compare/python_reference/`).
3. The Swift app runs its own STFT → Core ML → ISTFT pipeline on the same WAV (bundled
   as a resource), dumps its own `mag`/`m`/`xt` as raw float32 binaries plus the 6 stem
   WAVs, into the app's Documents directory.
4. `ml/scripts/compare_swift_output.py` diffs the two stem sets; the raw `mag`/`m`/`xt`
   dumps let a mismatch be localized to a specific stage instead of guessing.

### Bug found and fixed: vDSP inverse-FFT scale factor (off by exactly 2x)

First full-pipeline run: STFT matched Python's `mag` almost exactly (max abs diff
~1.9e-6), so the forward transform was right — but the final stems were badly wrong
(peaks off by large, inconsistent-looking factors per source). Narrowed it down with a
plain-numpy reimplementation of the ISTFT algorithm's *structure* (OLA + window
normalization + crop, no vDSP), checked against `HTDemucs._ispec` directly: that matched
to 1.6e-7, proving the algorithm itself (padding/cropping/window-normalization) was
correct. That isolated the bug to vDSP's specific inverse-FFT scale convention. Added a
direct empirical test — `HTDemucsSTFT.spec()` immediately followed by `.ispec()` on the
same real audio channel, comparing the round-tripped signal to the original — which
showed the reconstruction was consistently **exactly 2x** the original. Fixed by halving
the inverse-FFT normalization constant (see the comment at `HTDemucsSTFT.swift`'s
`invScale`). After the fix, the same round-trip test reproduces the original to
`~3e-5` (interior samples), and full-pipeline stems matched the Python reference to:

```
source     max abs diff   ref peak   verdict
drums      2.8e-05        1.1009     OK
bass       1.2e-05        0.6459     OK
other      1.4e-05        0.0874     OK
vocals     2.6e-05        0.9851     OK
guitar     2.9e-05        0.6370     OK
piano      2.7e-07        0.0042     OK
```

All within ~3e-5 of the Python reference (float32-precision-level agreement) — well
below any audible threshold.

### Simulator-only caveat: GPU/ANE Core ML backend fails on iOS Simulator

With the default `computeUnits = .all`, the console logged:
`E5RT encountered an STL exception... "MpsGraph backend validation on incompatible OS"`
— the simulator's GPU/ANE Core ML backend rejects this model outright. This is a known
category of iOS Simulator limitation (Core ML's ANE/GPU execution paths are not fully
supported in the simulator for all model shapes), not a bug in the model or the Swift
code. Worked around for simulator testing by forcing `computeUnits = .cpuOnly` under
`#if targetEnvironment(simulator)`, keeping `.all` for real devices (where the Neural
Engine path is expected to work normally — not yet confirmed on real hardware, see
below).

### Timing (simulator, CPU-only — NOT representative of real hardware)

Full pipeline on the 7.8s test clip, iPad Air 11" (M4) simulator, forced CPU-only:
STFT ~1.2s, Core ML predict ~2.5s, ISTFT+combine+write ~6.4s, total ~12s. This is
**slower than real-time** and must not be used to estimate real-device performance:
(a) CPU-only is an artificial simulator restriction, not what a real device would use
(the Neural Engine should be dramatically faster for the Core ML portion alone — the
Mac-side Python `.predict()` benchmark earlier measured ~0.29s for the same-size input
via ANE/GPU/CPU auto-dispatch), and (b) the Swift STFT/ISTFT code is a first-pass,
unoptimized implementation (per-frame nested-array allocations) with clear room to
speed up if it turns out to matter.

### Real iPad hardware run (2026-09-11) — succeeds, correctness confirmed, speed needs work

Ran on the paired physical device ("Yujin의 iPad", iPad Air 11" M3) via
`xcodebuild -destination 'platform=iOS,id=...'` + `xcrun devicectl device install/launch`
(`computeUnits = .all` — real Neural Engine/GPU/CPU auto-dispatch, no simulator
workaround needed). No crash, completed end-to-end.

**Correctness**: matches the Python reference even more tightly than the simulator run:

```
source     max abs diff   ref peak
drums      1.6e-06        1.1009
bass       1.5e-06        0.6459
other      6.6e-07        0.0874
vocals     9.6e-07        0.9851
guitar     1.0e-06        0.6370
piano      3.3e-07        0.0042
```

**Timing** (7.8s test segment, Debug build, one-time model load 0.88s not included below):
STFT 1.04s, Core ML inference **7.29s**, ISTFT+combine+write 5.30s, total 15.2s.

This is markedly slower than hoped, and slower than the Mac-side Python `.predict()`
benchmark (~0.29s) — almost certainly because the model runs at **FLOAT32** precision
(required to avoid the fp16 numerical blowup found earlier), and the Neural Engine's
efficient path is FP16; FP32 likely pushes much of the graph onto GPU/CPU instead of
ANE. The Swift STFT/ISTFT code is also an unoptimized first pass (per-frame
`[[Float]]` allocations), and this is a Debug (`-Onone`) build.

Rough extrapolation to a 4-minute (240s) song, naively splitting into
`ceil(240/7.8) ≈ 31` non-overlapping 7.8s segments (real demucs uses overlapping
segments for quality, so actual segment count would be somewhat higher) and reusing
the one-time model load: `31 × (1.04 + 7.29 + 5.30)s ≈ 31 × 13.6s ≈ 422s ≈ 7 minutes`.
**Too slow for a good user experience as-is** — see the Release-build results below,
which resolve this without needing mixed precision.

## Speed optimization pass (2026-09-11)

Per-stage bottleneck breakdown requested before reaching for mixed precision (the
costlier option). Cheapest fix first:

### Step 1: Release build — resolves the entire problem, no further optimization needed

Same test (7.8s segment, same physical iPad), only the Xcode configuration changed
from Debug to Release:

| stage | Debug | Release | speedup |
|---|---|---|---|
| STFT | 1.035s | 0.021s | ~49x |
| Core ML inference | 7.29s | 0.46s | ~16x |
| ISTFT + combine + write | 5.30s | 0.11s | ~47x |
| **total** (model load excluded, one-time) | 13.6s | 0.59s | ~23x |

Confirmed reproducible across two consecutive fresh launches (0.46s / 0.54s inference,
0.11s / 0.12s ISTFT) — not a one-off fluke. Re-ran `compare_swift_output.py` on the
Release build's output: **identical accuracy** to the Debug build and the earlier
correctness run (max abs diff ~1e-6 across all 6 stems) — Release's more aggressive
Swift optimizer does not change numerical results here.

The STFT/ISTFT speedup (~47-49x) is exactly what's expected from `-Onone` → `-O`
on hand-written nested-array Swift code — unsurprising. The **Core ML inference**
speedup (~16x) is more subtle: part of it is likely a warm Neural-Engine-compilation
cache from the immediately-prior Debug run on the same device (first Release launch:
0.94s model-load / 0.54s inference; second: 0.26s / 0.46s), not purely a Debug-vs-Release
effect — Core ML's own runtime isn't Swift-optimizer-sensitive the way hand-written code
is. Either way, 0.46-0.54s is now in the same ballpark as the Mac-side Python benchmark
(0.29s), confirming the FP32 model **is** running efficiently on this device once the
surrounding app isn't a Debug build — the earlier 7.29s Debug number was not a sign the
Neural Engine couldn't use FP32 well, just Debug-build overhead somewhere in the
Core ML call path (or cold-cache) dominating.

**Conclusion: mixed-precision conversion is not needed.** The two conditions the plan
called for testing it under (inference still far from the Python baseline; STFT/ISTFT
dominating the total) are both false after just switching to Release — stopped here per
that branch logic rather than doing the costlier FP16 work speculatively.

### Extrapolation to a 4-minute song

Using the Release per-segment numbers (STFT 0.021s + inference 0.46s + ISTFT 0.11s =
0.59s/segment) and the same non-overlapping ~31-segment approximation, plus one
one-time model load (~0.3-0.9s depending on cache state):

```
31 x 0.59s + ~0.5s (model load) ≈ 19s for a 4-minute song
```

**≈19 seconds to fully separate a 4-minute song**, roughly 12x faster than the song's
own length — comfortably fits CLAUDE.md's "처리 시간(수십초~수분) 동안 비동기 처리 +
진행률 UI" expectation. Caveats: this is extrapolated from one 7.8s segment repeated 31
times, not an actual full-song run; real demucs' overlapping-segment inference (used for
separation quality, not yet implemented in this Swift pipeline) would add somewhat more
segments/compute than this simple non-overlapping estimate.
