#!/usr/bin/env bash
# Builds an audio-only FFmpeg (static libavformat/libavcodec/libswresample/libavutil) for
# iOS 12 arm64 plus LiteP's in-process `-c copy` wrapper (native/ffmpeg).
set -euo pipefail
VERSION=7.1.2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ffmpeg"
LIBS="$ROOT/build/ffmpeg-libs"   # cached between CI runs
WORK="$ROOT/build/ffmpeg-src"
SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CC="$(xcrun -sdk iphoneos -f clang)"
FLAGS="-arch arm64 -miphoneos-version-min=12.0"

if [ ! -f "$LIBS/.version-$VERSION" ]; then
  rm -rf "$LIBS" "$WORK"
  mkdir -p "$WORK"
  curl -fsSL "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" | tar -xJ -C "$WORK" --strip-components=1
  (cd "$WORK" && ./configure --prefix="$LIBS" \
    --enable-cross-compile --target-os=darwin --arch=aarch64 --cc="$CC" --sysroot="$SDK" \
    --extra-cflags="$FLAGS -Os" --extra-ldflags="$FLAGS" \
    --enable-static --disable-shared --enable-pic --enable-small \
    --disable-programs --disable-doc --disable-debug --disable-autodetect --enable-zlib \
    --disable-everything --disable-avdevice --disable-avfilter --disable-swscale --disable-postproc --disable-network \
    --enable-protocol=file \
    --enable-demuxer=hls,mov,mp3,ogg,flac,matroska,aac,mpegts \
    --enable-muxer=mov,mp4,ipod,mp3,ogg,opus,flac,matroska,adts \
    --enable-decoder=aac,mp3,mp3float,opus,flac,alac \
    --enable-parser=aac,mpegaudio,opus,flac \
    --enable-bsf=aac_adtstoasc)
  make -C "$WORK" -j "$(sysctl -n hw.ncpu)"
  make -C "$WORK" install
  touch "$LIBS/.version-$VERSION"
fi

rm -rf "$OUT"
mkdir -p "$OUT/include"
cp "$LIBS"/lib/libavformat.a "$LIBS"/lib/libavcodec.a "$LIBS"/lib/libswresample.a "$LIBS"/lib/libavutil.a "$OUT/"
"$CC" $FLAGS -isysroot "$SDK" -Os -Wall -c "$ROOT/native/ffmpeg/lite_ffmpeg.c" -I "$LIBS/include" -o "$OUT/lite_ffmpeg.o"
xcrun -sdk iphoneos ar rcs "$OUT/libliteffmpeg.a" "$OUT/lite_ffmpeg.o"
rm "$OUT/lite_ffmpeg.o"
cp "$ROOT/native/ffmpeg/lite_ffmpeg.h" "$ROOT/native/ffmpeg/module.modulemap" "$OUT/include/"
ls -la "$OUT" "$OUT/include"
