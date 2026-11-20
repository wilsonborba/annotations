#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT/native/pdf_krilla"
WASM_OUT="$ROOT/common/annotations_shared/lib/presentation/frontend/assets/wasm/pdf_krilla.wasm"
JNI_OUT="$ROOT/apps/local/android/app/src/main/jniLibs"
APPLE_OUT="$CRATE_DIR/target/apple"

export PATH="$HOME/.cargo/bin:$PATH"
export TMPDIR="${TMPDIR:-$HOME/.cache/agi-impl/tmp}"
mkdir -p "$TMPDIR"

MODE="${1:-all}"

build_linux() {
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib
}

build_wasm() {
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib --target wasm32-unknown-unknown
  mkdir -p "$(dirname "$WASM_OUT")"
  cp "$CRATE_DIR/target/wasm32-unknown-unknown/release/pdf_krilla.wasm" "$WASM_OUT"
}

build_android() {
  local ndk_dir="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-$(ls -d "$HOME"/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -n1 || true)}}"
  if [ -z "$ndk_dir" ] || [ ! -d "$ndk_dir" ]; then
    echo "Android NDK not found; set ANDROID_NDK_ROOT" >&2
    exit 1
  fi
  local llvm_bin="$ndk_dir/toolchains/llvm/prebuilt/linux-x86_64/bin"
  local pairs=(
    "aarch64-linux-android:arm64-v8a:aarch64-linux-android24-clang"
    "armv7-linux-androideabi:armeabi-v7a:armv7a-linux-androideabi24-clang"
    "x86_64-linux-android:x86_64:x86_64-linux-android24-clang"
    "i686-linux-android:x86:i686-linux-android24-clang"
  )
  for entry in "${pairs[@]}"; do
    IFS=':' read -r target abi clang <<<"$entry"
    local env_key="CARGO_TARGET_$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_LINKER"
    export "$env_key=$llvm_bin/$clang"
    cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib --target "$target"
    mkdir -p "$JNI_OUT/$abi"
    cp "$CRATE_DIR/target/$target/release/libpdf_krilla.so" "$JNI_OUT/$abi/libpdf_krilla.so"
  done
}

build_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "macOS build requires macOS/Xcode host" >&2
    exit 1
  fi
  mkdir -p "$APPLE_OUT"
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib --target aarch64-apple-darwin
  cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib --target x86_64-apple-darwin
  lipo -create \
    "$CRATE_DIR/target/aarch64-apple-darwin/release/libpdf_krilla.a" \
    "$CRATE_DIR/target/x86_64-apple-darwin/release/libpdf_krilla.a" \
    -output "$APPLE_OUT/libpdf_krilla_macos.a"
}

build_ios() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "iOS build requires macOS/Xcode host" >&2
    exit 1
  fi
  mkdir -p "$APPLE_OUT"
  if [ "${PLATFORM_NAME:-iphoneos}" = "iphonesimulator" ]; then
    cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib --target aarch64-apple-ios-sim
    cp "$CRATE_DIR/target/aarch64-apple-ios-sim/release/libpdf_krilla.a" "$APPLE_OUT/libpdf_krilla_ios.a"
  else
    cargo build --manifest-path "$CRATE_DIR/Cargo.toml" --locked --release --lib --target aarch64-apple-ios
    cp "$CRATE_DIR/target/aarch64-apple-ios/release/libpdf_krilla.a" "$APPLE_OUT/libpdf_krilla_ios.a"
  fi
}

case "$MODE" in
  linux) build_linux ;;
  wasm) build_wasm ;;
  android) build_android ;;
  macos) build_macos ;;
  ios) build_ios ;;
  all)
    build_linux
    build_wasm
    if [ "$(uname -s)" = "Darwin" ]; then
      build_macos
    fi
    ;;
  *)
    echo "Usage: $0 {linux|wasm|android|macos|ios|all}" >&2
    exit 2
    ;;
esac
