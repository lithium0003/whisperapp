import torch
from torch import nn

import coremltools as ct

import whisper
from whisper.model import Linear

model = whisper.load_model("large-v3", device="cpu")
model.eval()

new_outdim = [0 for _ in range(len(model.encoder.blocks))]
input_shape = (1, model.dims.n_mels, 3000)

test_input_data = torch.randn(input_shape)
model.encoder.eval()
with torch.no_grad():
    initial_result = model.encoder(test_input_data)

for block_id in range(len(model.encoder.blocks)):
    print(f'block {block_id} / {len(model.encoder.blocks)}')

    orglinear1 = model.encoder.blocks[block_id].mlp[0]
    orglinear2 = model.encoder.blocks[block_id].mlp[2]

    with torch.no_grad():
        value1 = torch.abs(orglinear1.weight).matmul(torch.ones(orglinear1.in_features, orglinear1.out_features))
        mask = torch.eye(orglinear1.out_features)
        value2 = torch.abs(orglinear2.weight).matmul(value1 * mask)
        sortvalue, idx = torch.sort(value2.mean(dim=0), descending=True)
        cut_len = (sortvalue < 0.08).sum().detach().numpy()
        cut_len = cut_len - cut_len % 64
        if cut_len > orglinear1.out_features // 2:
            cut_len = orglinear1.out_features // 2
        if cut_len < 100:
            cut_len = 0
        new_outdim[block_id] = orglinear1.out_features - cut_len
        print('used value:', sortvalue[0], sortvalue[-cut_len])
        print('unuse value:', cut_len, sortvalue[-1])
        select_idx = idx[:new_outdim[block_id]]

    if cut_len == 0:
        continue

    mlp = nn.Sequential(
        Linear(orglinear1.in_features, new_outdim[block_id]),
        nn.GELU(), 
        Linear(new_outdim[block_id], orglinear2.out_features),
    )

    with torch.no_grad():
        w = orglinear1.weight[select_idx, :]
        mlp[0].weight.data.copy_(w)
        b = orglinear1.bias[select_idx]
        mlp[0].bias.data.copy_(b)
        w = orglinear2.weight[:, select_idx]
        mlp[2].weight.data.copy_(w)
        b = orglinear2.bias
        mlp[2].bias.data.copy_(b)

    model.encoder.blocks[block_id].mlp = mlp

model.encoder.eval()
with torch.no_grad():
    result0 = model.encoder(test_input_data)
print('diff:', (result0 - initial_result).abs().mean())

encoder = model.encoder
print(encoder)

encoder.eval()
# torch.save({
#             'dims': model.dims,
#             'outdim': new_outdim,
#             'model_state_dict': encoder.to('cpu').state_dict(),
#             }, 'encoder.pth')

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
mlmodel.save(f"ggml-large-v3-encoder.mlpackage")
