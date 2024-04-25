from typing import Iterable

import torch

import whisper
from fix_model import ANEAudioEncoder

checkpoint = torch.load('encoder.pth')
dims = checkpoint['dims']
outdim = checkpoint['outdim']
encoder = ANEAudioEncoder(dims, outdim)
encoder.load_state_dict(checkpoint["model_state_dict"])

model = whisper.load_model("large-v3", device="cpu")

print(encoder)
print(model.encoder)

model.encoder.eval()
encoder.eval()

input_shape = (1, model.dims.n_mels, 3000)
input_data = torch.randn(input_shape)

with torch.no_grad():
    org_value = model.encoder(input_data)[0]
    fix_value = encoder(input_data)[0]

print(org_value)
print(fix_value)
print(fix_value - org_value)

import matplotlib.pyplot as plt
plt.subplot(2,2,1)
plt.imshow(org_value, vmin=-1, vmax=1)
plt.subplot(2,2,2)
plt.imshow(fix_value, vmin=-1, vmax=1)
plt.subplot(2,2,3)
plt.imshow(fix_value - org_value, vmin=-0.1, vmax=0.1)
plt.show()
