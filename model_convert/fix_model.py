from torch import nn

from whisper.model import AudioEncoder, Linear

class ANEAudioEncoder(AudioEncoder):
    def __init__(self, dims, hidden_dims):
        self.dims = dims
        self.hidden_dims = hidden_dims
        super().__init__(dims.n_mels, dims.n_audio_ctx, dims.n_audio_state, dims.n_audio_head, dims.n_audio_layer)

        for block_id in range(dims.n_audio_layer):
            orglinear1 = self.blocks[block_id].mlp[0]
            orglinear2 = self.blocks[block_id].mlp[2]
            mlp = nn.Sequential(
                Linear(orglinear1.in_features, hidden_dims[block_id]),
                nn.GELU(), 
                Linear(hidden_dims[block_id], orglinear2.out_features),
            )
            self.blocks[block_id].mlp = mlp
