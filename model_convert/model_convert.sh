#!/bin/bash

cd $(dirname $0)
bash download_whisper.sh

if [ ! -d whisper.cpp ]; then
    git clone --depth=1 https://github.com/ggerganov/whisper.cpp.git && cd whisper.cpp
    make -j quantize
    cd ..
fi

for model in "large-v3-turbo" "large-v3" "medium" "small" "base" "tiny"
do
    python3 convert_coreml.py $model
    if [ -d ggml-$model-encoder ]; then
        xcrun coremlcompiler compile ggml-$model-encoder/chunked_pipeline.mlpackage .
        rm -rf ggml-$model-encoder.mlmodelc
        mv chunked_pipeline.mlmodelc ggml-$model-encoder.mlmodelc
    else
        xcrun coremlcompiler compile ggml-$model-encoder.mlpackage .
    fi
    bash download_model.sh $model
    python3 convert-h5-to-ggml-decoder.py $model . .
    whisper.cpp/quantize ggml-model.bin ggml-${model}-q8_0.bin q8_0
    rm ggml-model.bin
done

mkdir -p model_output
mv *.mlmodelc model_output/
mv ggml-*.bin model_output/

rm -rf *.mlpackage
rm -rf ggml-*-encoder
rm -rf large-v3-turbo large-v3 medium small base tiny
rm -rf whisper whisper.cpp

cd model_output
mkdir -p index
for model in "large-v3-turbo" "large-v3" "medium" "small" "base" "tiny"
do
    find * -type f | grep "ggml-${model}-\(q8_0\|encoder\)" > index/${model}    
done
cd ..
