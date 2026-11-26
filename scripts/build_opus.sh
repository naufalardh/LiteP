#!/usr/bin/env bash
# Builds a static libopus (decoder used to turn .opus downloads into AAC) for iOS 12 arm64.
set -euo pipefail
VERSION=1.5.2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/opus"
WORK="$ROOT/build/opus-src"
rm -rf "$OUT" "$WORK"
mkdir -p "$WORK" "$OUT/include"
curl -fsSL "https://downloads.xiph.org/releases/opus/opus-$VERSION.tar.gz" | tar -xz -C "$WORK" --strip-components=1
cmake -S "$WORK" -B "$WORK/build" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
  -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF
cmake --build "$WORK/build" --config Release -j "$(sysctl -n hw.ncpu)"
cp "$WORK/build/libopus.a" "$OUT/"
cp "$WORK"/include/*.h "$OUT/include/"
cat > "$OUT/include/module.modulemap" <<'MAP'
module COpus {
    header "opus.h"
    export *
}
MAP
ls -la "$OUT" "$OUT/include"
