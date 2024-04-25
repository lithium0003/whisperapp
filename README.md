# Whisper transcribe app
This repo is iOS/macOS app "Whisper transcribe app" source code.

<img src="https://github.com/lithium0003/whisperapp/assets/4783887/6cd31c5b-2921-4fd4-8ba0-4f678f1a2d78" width="200">
<img src="https://github.com/lithium0003/whisperapp/assets/4783887/92dd5c76-b608-4473-8710-2571d729825d" width="200">
<img src="https://github.com/lithium0003/whisperapp/assets/4783887/f60593e9-442e-49c2-8f1f-e884528b3b39" width="200">

# Description
This app transcribe multi language speech with OpenAI Whisper model.
All process is on device, no data leaks outside.
Quantization and trimming unused weights, the most precise and largest model, large-v3 run on iPhone15 Pro in realtime.

model is converted to ggml format (https://github.com/ggerganov/whisper.cpp) and CoreML format.
CoreML model run fast only encoder, so convet encoder to CoreML, convert decoder to ggml format.

# Build
## Model weight conversion
Model weight conversion step
1. prepare python env
2. run ```model_convert/install.sh```
3. run ```model_convert/model_convert.sh```
4. output in ```model_convert/model_output/```

Converted models are placed in some web to download from app.

Store app uses the weight https://huggingface.co/lithium0003/ggml-coreml-whisper

## App compile
Open ```whisperapp.xcodeproj``` with Xcode and run.
