# Transcribe on device
This repo is iOS/macOS app "Transcribe on device" source code.

Store app: 
https://apps.apple.com/en/app/id6499276794

<img src="https://github.com/user-attachments/assets/38db0843-9a08-48ab-bf14-4f7354f2c3f1" width="200">
<img src="https://github.com/user-attachments/assets/4a4c6944-928c-4290-b9e6-b657a30c2634" width="200">
<img src="https://github.com/user-attachments/assets/42502509-e04e-4979-bc00-65c5197dd45b" width="200">
<img src="https://github.com/user-attachments/assets/939b7491-cf60-48c8-8a37-446bfbf37525" width="200">

## Application demo
large-v3 model running on iPhone15 Pro 
https://youtu.be/sOuw789yj1k

# Description
This app transcribe multi language speech with OpenAI Whisper model.
All process is on device, no data leaks outside.
Quantization weights and split CoreML model, the most precise and largest model, large-v3 run on iPhone15 Pro in realtime.

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

## whisper.cpp build
run ```./build.sh```

## App compile
Open ```whisperapp.xcodeproj``` with Xcode and run.
