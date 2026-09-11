"""Lightweight onset-detection CNN.

Architecture follows Schlüter & Böck (2014): a small 2D-conv stack over a short
mel-spectrogram context window, ending in a single sigmoid output (onset probability
for the center frame). Kept intentionally tiny (~tens of thousands of params) with
Core ML conversion in mind later — no attention, no complex ops, just Conv2d/Linear/
ReLU/BatchNorm/MaxPool/Sigmoid, all straightforwardly convertible.

Input: [B, 1, N_MELS, CONTEXT_FRAMES] (log-mel window)
Output: [B] onset probability for the window's center frame
"""
from __future__ import annotations

import torch
from torch import nn

from melspec import N_MELS, CONTEXT_FRAMES


class OnsetCNN(nn.Module):
    def __init__(self, n_mels: int = N_MELS, context_frames: int = CONTEXT_FRAMES):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 16, kernel_size=(3, 3), padding=(1, 1))
        self.bn1 = nn.BatchNorm2d(16)
        self.pool1 = nn.MaxPool2d(kernel_size=(3, 1))  # pool over mel axis only

        self.conv2 = nn.Conv2d(16, 32, kernel_size=(3, 3), padding=(1, 1))
        self.bn2 = nn.BatchNorm2d(32)
        self.pool2 = nn.MaxPool2d(kernel_size=(3, 1))

        self.conv3 = nn.Conv2d(32, 32, kernel_size=(3, 3), padding=(1, 1))
        self.bn3 = nn.BatchNorm2d(32)

        self.relu = nn.ReLU(inplace=True)

        with torch.no_grad():
            dummy = torch.zeros(1, 1, n_mels, context_frames)
            flat_dim = self._features(dummy).numel()

        self.fc1 = nn.Linear(flat_dim, 64)
        self.dropout = nn.Dropout(0.3)
        self.fc2 = nn.Linear(64, 1)

    def _features(self, x: torch.Tensor) -> torch.Tensor:
        x = self.pool1(self.relu(self.bn1(self.conv1(x))))
        x = self.pool2(self.relu(self.bn2(self.conv2(x))))
        x = self.relu(self.bn3(self.conv3(x)))
        return x

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        # x: [B, N_MELS, CONTEXT_FRAMES] -> add channel dim
        if x.dim() == 3:
            x = x.unsqueeze(1)
        x = self._features(x)
        x = x.flatten(1)
        x = self.relu(self.fc1(x))
        x = self.dropout(x)
        logit = self.fc2(x).squeeze(-1)
        return logit  # raw logit; apply sigmoid outside (BCEWithLogitsLoss expects logits)


def count_params(model: nn.Module) -> int:
    return sum(p.numel() for p in model.parameters())


if __name__ == "__main__":
    m = OnsetCNN()
    n = count_params(m)
    print(f"OnsetCNN parameters: {n:,} (~{n * 4 / 1024:.1f} KB as float32)")
    x = torch.randn(8, N_MELS, CONTEXT_FRAMES)
    out = m(x)
    print("output shape:", out.shape)
