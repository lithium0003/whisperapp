#!/bin/sh

find whisper.cpp -name 'ggml-alloc.h'   | grep include | xargs -I{} cp {} whisper/Sources/whisper/include/
find whisper.cpp -name 'ggml-backend.h' | grep include | xargs -I{} cp {} whisper/Sources/whisper/include/
find whisper.cpp -name 'ggml-cpu.h'     | grep include | xargs -I{} cp {} whisper/Sources/whisper/include/
find whisper.cpp -name 'ggml.h'         | grep include | xargs -I{} cp {} whisper/Sources/whisper/include/
find whisper.cpp -name 'whisper.h'      | grep include | xargs -I{} cp {} whisper/Sources/whisper/include/

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
	-DCMAKE_OSX_SYSROOT=iphoneos \
	-DGGML_STATIC=ON \
	-DBUILD_SHARED_LIBS=OFF 
cmake --build . --config Release -j $(sysctl -n hw.logicalcpu) -- CODE_SIGNING_ALLOWED=NO
)
find whisper.cpp/build -name '*.a' | xargs libtool -static -o whisper/whisper.xcframework/ios-arm64/whisper.a
rm -rf whisper.cpp/build

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
	-DGGML_STATIC=ON \
	-DBUILD_SHARED_LIBS=OFF 

cmake --build . --config Release -j $(sysctl -n hw.logicalcpu) -- CODE_SIGNING_ALLOWED=NO
)
find whisper.cpp/build -name '*.a' | xargs libtool -static -o whisper/whisper.xcframework/mac-arm64/whisper.a
rm -rf whisper.cpp/build
