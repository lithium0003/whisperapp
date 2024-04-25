#!/bin/bash

whisper_assets="whisper/assets"

mkdir -p $whisper_assets && cd $whisper_assets
if [ ! -f mel_filters.npz ]; then
    curl -L -O "https://github.com/openai/whisper/raw/main/whisper/assets/mel_filters.npz"
fi
