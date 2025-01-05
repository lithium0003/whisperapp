#!/bin/sh
(
cd whisper.cpp
rm -rf build && mkdir build && cd build

cmake -G Xcode .. \
	-DGGML_METAL_USE_BF16=ON \
	-DGGML_METAL_EMBED_LIBRARY=ON \
	-DWHISPER_BUILD_EXAMPLES=OFF \
	-DWHISPER_BUILD_TESTS=OFF \
	-DWHISPER_BUILD_SERVER=OFF \
	-DWHISPER_COREML=ON \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_SYSROOT=iphoneos

cmake --build . --config Release -j $(sysctl -n hw.logicalcpu) -- CODE_SIGNING_ALLOWED=NO
)

whisperapp/whisper.cpp/lib_ios/copyfiles.sh

(
cd whisper.cpp
rm -rf build && mkdir build && cd build

cmake -G Xcode .. \
	-DGGML_METAL_USE_BF16=ON \
	-DGGML_METAL_EMBED_LIBRARY=ON \
	-DWHISPER_BUILD_EXAMPLES=OFF \
	-DWHISPER_BUILD_TESTS=OFF \
	-DWHISPER_BUILD_SERVER=OFF \
	-DWHISPER_COREML=ON 

cmake --build . --config Release -j $(sysctl -n hw.logicalcpu) -- CODE_SIGNING_ALLOWED=NO
)

whisperapp/whisper.cpp/lib_mac/copyfiles.sh

rm -rf whisper.cpp/build
