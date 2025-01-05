#!/bin/sh
cd $(dirname $0)
find ../../../whisper.cpp/build -name '*.dylib' | xargs -I{} cp {} . 
