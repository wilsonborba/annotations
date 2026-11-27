#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/annotations-package-helper-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
source "$ROOT_DIR/scripts/package_helpers.sh"

app="$work/Annotations.app"
mkdir -p "$app/Contents/MacOS"
printf 'fixture\n' > "$app/Contents/Info.plist"
printf '#!/bin/sh\n' > "$app/Contents/MacOS/Annotations"
chmod 0755 "$app/Contents/MacOS/Annotations"
validate_macos_executable "$app" Annotations
if validate_macos_executable "$app" annotations_local; then
  printf 'accepted a non-bundle executable name\n' >&2
  exit 1
fi

dist="$work/dist"
mkdir -p "$dist"
printf 'arm archive\n' > "$dist/annotations-macos-arm64.zip"
printf 'x64 archive\n' > "$dist/annotations-macos-x64.zip"
write_package_checksums "$dist" macos > "$dist/SHA256SUMS"
for asset in annotations-macos-arm64.zip annotations-macos-x64.zip; do
  expected="$(shasum -a 256 "$dist/$asset" | awk '{print $1}')"
  recorded="$(awk -v name="$asset" '$2 == name { print $1 }' "$dist/SHA256SUMS")"
  [[ "$recorded" == "$expected" ]]
done

printf 'package helper fixture passed\n'
