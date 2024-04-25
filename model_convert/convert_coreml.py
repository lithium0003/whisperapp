import torch
from torch import nn
import sys

import coremltools as ct

import whisper
from whisper.model import Linear

model_size = sys.argv[1]

model = whisper.load_model(model_size, device="cpu")

encoder = model.encoder
encoder.eval()
print(encoder)

input_shape = (1, model.dims.n_mels, 3000)
input_data = torch.randn(input_shape)
traced_model = torch.jit.trace(encoder, input_data)

mlmodel = ct.convert(
    traced_model,
    convert_to="mlprogram",
    inputs=[ct.TensorType(name="logmel_data", shape=input_shape)],
    outputs=[ct.TensorType(name="output")],
    compute_units=ct.ComputeUnit.CPU_AND_NE,
    minimum_deployment_target=ct.target.iOS17,
)
mlmodel.save(f"ggml-{model_size}-encoder.mlpackage")
