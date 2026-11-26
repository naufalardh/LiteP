#!/usr/bin/env bash
# Builds the Mornye Rust backend (vendor/Mornye/rust_backend) for arm64 iOS 12
# and stages the static library and UniFFI Swift bindings in build/backend.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT/vendor/Mornye/rust_backend"
OUT="$ROOT/build/backend"

cd "$RUST_DIR"
export CARGO_TARGET_DIR="$RUST_DIR/target"
export LIBSQLITE3_FLAGS="${LIBSQLITE3_FLAGS:-} -USQLITE_ENABLE_FTS3 -USQLITE_ENABLE_FTS3_PARENTHESIS -USQLITE_ENABLE_RTREE -USQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_GET_TABLE -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_COMPLETE -DSQLITE_OMIT_TCL_VARIABLE"

# Host library, only used to generate the Swift bindings.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
cargo build --locked --release -p mornye-mobile
cargo run --locked -p mornye-bindgen -- generate \
  --library "$CARGO_TARGET_DIR/release/libmornye_mobile.dylib" \
  --language swift \
  --out-dir "$CARGO_TARGET_DIR/bindings/swift" \
  --no-format

export IPHONEOS_DEPLOYMENT_TARGET=12.0
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="$SDK"
export CFLAGS_aarch64_apple_ios="-mios-version-min=12.0"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="--target=arm64-apple-ios12.0 -isysroot $SDK"
rustup target add aarch64-apple-ios
cargo build --locked --release -p mornye-mobile --target aarch64-apple-ios

rm -rf "$OUT"
mkdir -p "$OUT/include"
cp "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libmornye_mobile.a" "$OUT/"
cp "$CARGO_TARGET_DIR/bindings/swift/MornyeBackend.swift" "$OUT/"
cp "$CARGO_TARGET_DIR/bindings/swift/MornyeBackendFFI.h" "$OUT/include/"
cp "$CARGO_TARGET_DIR/bindings/swift/MornyeBackendFFI.modulemap" "$OUT/include/module.modulemap"
ls -la "$OUT" "$OUT/include"
