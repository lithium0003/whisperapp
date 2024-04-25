#!/bin/bash

#model_size='large-v3'
model_size=$1

mkdir -p $model_size && cd $model_size
curl -L -O "https://huggingface.co/openai/whisper-${model_size}/raw/main/vocab.json"
curl -L -O "https://huggingface.co/openai/whisper-${model_size}/raw/main/added_tokens.json"
curl -L -O "https://huggingface.co/openai/whisper-${model_size}/raw/main/config.json"
