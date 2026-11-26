#!/bin/zsh
# Builds Murmur.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
LIB=$ROOT/vendor/transcribe.cpp/build
APP=$ROOT/build/Murmur.app

if [[ ! -f $LIB/src/libtranscribe.a ]]; then
  (cd vendor/transcribe.cpp && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF && cmake --build build -j 16 --target transcribe)
fi

rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos26.5 \
  -I CTranscribe -module-name Murmur \
  Sources/Murmur/*.swift -o "$APP/Contents/MacOS/Murmur" \
  -L $LIB/src -L $LIB/ggml/src -L $LIB/ggml/src/ggml-metal \
  -ltranscribe -lggml -lggml-metal -lggml-cpu -lggml-base -lc++ \
  -framework Metal -framework MetalKit -framework Accelerate -framework Foundation
cp Resources/Info.plist "$APP/Contents/Info.plist"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier dev.elias.murmur "$APP"

mkdir -p ~/Applications
pkill -x Murmur 2>/dev/null || true
rm -rf ~/Applications/Murmur.app; cp -R "$APP" ~/Applications/Murmur.app
echo "Installed ~/Applications/Murmur.app"
