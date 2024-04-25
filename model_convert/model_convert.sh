#!/bin/bash

if [ ! -d whisper.cpp ]; then
    git clone --depth=1 https://github.com/ggerganov/whisper.cpp.git && cd whisper.cpp
    make -j quantize
    cd ..
fi

model="large-v3"
python3 large-v3_coreml.py
xcrun coremlcompiler compile ggml-$model-encoder.mlpackage .
bash download_whisper.sh
bash download_model.sh $model
python3 convert-h5-to-ggml-decoder.py $model . .
whisper.cpp/quantize ggml-model.bin ggml-large-v3-q8_0.bin q8_0
rm ggml-model.bin

for model in "medium" "small" "base" "tiny"
do
    python3 convert_coreml.py $model
    xcrun coremlcompiler compile ggml-$model-encoder.mlpackage .
    bash download_model.sh $model
    python3 convert-h5-to-ggml-decoder.py $model . .
    mv ggml-model.bin ggml-${model}.bin
done

mkdir -p model_output
mv *.mlmodelc model_output/
mv ggml-*.bin model_output/

rm -rf *.mlpackage
rm -rf large-v3 medium small base tiny
rm -rf whisper whisper.cpp

cd model_output
mkdir -p index
for model in "large-v3" "medium" "small" "base" "tiny"
do
    find * -type f | grep ggml-${model} > index/${model}    
done
cd ..
