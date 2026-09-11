"""Split htdemucs_6s into Pre / Core / Post stages around its STFT/ISTFT calls.

Why: Core ML's MIL IR has no complex-number dtype, but `torch.stft`/`torch.istft`
(called from demucs/spec.py: spectro()/ispectro(), via HTDemucs._spec()/_ispec()) produce
and consume complex64 tensors. Everything else in the model (encoder/decoder convs, the
cross-transformer, the time-branch tconv stack) is pure real-valued arithmetic. This module
draws the boundary so only the real-valued middle can be traced/converted to Core ML, while
STFT/ISTFT stay in plain PyTorch/Accelerate outside the Core ML graph.

Model facts (htdemucs_6s, from live inspection — see README.md "STFT/ISTFT parameters"):
  cac=True (complex-as-channels), wiener_iters=0 (irrelevant when cac=True — the cac branch
  in HTDemucs._mask() never touches the mixture spectrogram or runs Wiener filtering),
  nfft=4096, hop_length=1024, audio_channels=2, sources=[drums,bass,other,vocals,guitar,piano],
  samplerate=44100, use_train_segment=True, segment=39/5 -> training_length=343980 samples.

Three stages, matching HTDemucs.forward() exactly (verified against demucs 4.1.0 source):

  Pre  (plain PyTorch, NOT traced for Core ML):
    mix [B,C,L] --(pad to training_length if shorter)--> mix_padded
    z = model._spec(mix_padded)          # torch.stft, complex64, shape [B,C,Fq,T]
    mag = model._magnitude(z)            # torch.view_as_real + reshape, REAL, [B,C*2,Fq,T]

  Core (HTDemucsCore below — this is what gets traced/converted):
    inputs:  mag [B,C*2,Fq,T] real, mix_padded [B,C,L] real
    outputs: m  [B,S,C*2,Fq,T] real  (pre-complex per-source "mask" spectrogram)
             xt [B,S,C,L]       real  (time-branch waveform, already de-normalized)
    Body = HTDemucs.forward()'s encoder -> freq_emb -> crosstransformer -> decoder loop,
    verbatim, MINUS: the _spec/_magnitude call at the top (replaced by the `mag` input),
    and the _mask/_ispec call at the bottom (moved to Post). Zero complex ops inside.

  Post (plain PyTorch, NOT traced for Core ML):
    zout = view_as_complex(m reshaped)   # inverse of _magnitude's packing, complex64
    x = model._ispec(zout, ispec_length) # torch.istft, REAL, [B,S,C,L]
    out = xt + x                         # sum time-branch + freq-branch (both real)
    out = out[..., :length_pre_pad]      # only if the input was shorter than training_length

Real/imag channel packing (the exact interface Swift must reproduce later):
  Both `mag` (Pre's output) and `m` (Core's output) use IDENTICAL packing along the
  channel axis: for each audio channel c in [0, audio_channels), the two entries
  [real(c), imag(c)] sit at consecutive channel indices 2*c, 2*c+1. For stereo
  (audio_channels=2) that's channel order [ch0_real, ch0_imag, ch1_real, ch1_imag].
  `m`'s full channel axis is (source, that same 2*audio_channels pattern) — sources are
  their own leading dim (S), not interleaved into the channel axis.
  This comes directly from HTDemucs._magnitude's `torch.view_as_real(z).permute(0,1,4,2,3)
  .reshape(B, C*2, Fr, T)` (view_as_real appends a trailing [real,imag] axis; permuting it
  next-to-last then reshaping merges (channel, real/imag) in that row-major order) and from
  the exactly inverse reshape in HTDemucs._mask's cac branch.
"""
from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F
from einops import rearrange


def compute_lengths(model, mix: torch.Tensor):
    """Reproduce HTDemucs.forward()'s top-of-function length/padding bookkeeping."""
    length = mix.shape[-1]
    length_pre_pad = None
    training_length = None
    if model.use_train_segment:
        training_length = int(model.segment * model.samplerate)
        if mix.shape[-1] < training_length:
            length_pre_pad = mix.shape[-1]
            mix = F.pad(mix, (0, training_length - length_pre_pad))
    return mix, length, length_pre_pad, training_length


def pre_process(model, mix: torch.Tensor):
    """Pre stage: STFT + magnitude packing. Plain PyTorch, complex64 involved — never traced."""
    mix_padded, length, length_pre_pad, training_length = compute_lengths(model, mix)
    z = model._spec(mix_padded)           # complex64 [B, C, Fq, T]
    mag = model._magnitude(z)             # real     [B, C*2, Fq, T]  (cac=True path)
    return mag, mix_padded, length, length_pre_pad, training_length


class HTDemucsCore(nn.Module):
    """Pure-real subgraph of HTDemucs: encoder/crosstransformer/decoder only.

    Verbatim copy of HTDemucs.forward()'s middle section (demucs 4.1.0), with the
    _spec/_magnitude call replaced by a `mag` input and the _mask/_ispec call removed
    (moved to post_process below). No torch.stft/istft, no complex dtype anywhere.
    """

    def __init__(self, model):
        super().__init__()
        self.model = model  # reuse the pretrained submodules directly, no weight copy

    def forward(self, mag: torch.Tensor, mix: torch.Tensor):
        model = self.model
        B, C, Fq, T = mag.shape
        x = mag

        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)

        xt = mix
        meant = xt.mean(dim=(1, 2), keepdim=True)
        stdt = xt.std(dim=(1, 2), keepdim=True)
        xt = (xt - meant) / (1e-5 + stdt)

        saved = []
        saved_t = []
        lengths = []
        lengths_t = []
        for idx, encode in enumerate(model.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if idx < len(model.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = model.tencoder[idx]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if idx == 0 and model.freq_emb is not None:
                frs = torch.arange(x.shape[-2], device=x.device)
                emb = model.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                x = x + model.freq_emb_scale * emb
            saved.append(x)

        if model.crosstransformer:
            if model.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)")
                x = model.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = model.channel_upsampler_t(xt)

            x, xt = model.crosstransformer(x, xt)

            if model.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)")
                x = model.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f)
                xt = model.channel_downsampler_t(xt)

        for idx, decode in enumerate(model.decoder):
            skip = saved.pop(-1)
            x, pre = decode(x, skip, lengths.pop(-1))

            offset = model.depth - len(model.tdecoder)
            if idx >= offset:
                tdec = model.tdecoder[idx - offset]
                length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]
                    xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1)
                    xt, _ = tdec(xt, skip, length_t)

        S = len(model.sources)
        x = x.view(B, S, -1, Fq, T)
        x = x * std[:, None] + mean[:, None]

        xt = xt.view(B, S, -1, xt.shape[-1])
        xt = xt * stdt[:, None] + meant[:, None]

        return x, xt


def post_process(model, m: torch.Tensor, xt: torch.Tensor, length: int,
                  length_pre_pad, training_length):
    """Post stage: reassemble complex spectrogram + ISTFT. Plain PyTorch, never traced."""
    B, S, C2, Fr, T = m.shape
    out = m.view(B, S, -1, 2, Fr, T).permute(0, 1, 2, 4, 5, 3)
    zout = torch.view_as_complex(out.contiguous())          # [B, S, C, Fr, T] complex64

    ispec_length = training_length if model.use_train_segment else length
    x = model._ispec(zout, ispec_length)                     # [B, S, C, L] real

    out = xt + x
    if length_pre_pad:
        out = out[..., :length_pre_pad]
    return out


def split_forward(model, core: "HTDemucsCore", mix: torch.Tensor):
    """Full Pre -> Core -> Post pipeline, for numeric-equivalence testing against
    the model's own unmodified forward()."""
    mag, mix_padded, length, length_pre_pad, training_length = pre_process(model, mix)
    m, xt = core(mag, mix_padded)
    return post_process(model, m, xt, length, length_pre_pad, training_length)
