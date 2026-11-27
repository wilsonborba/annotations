#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/package_helpers.sh"
APP_DIR="$ROOT_DIR/apps/local"
DIST_DIR="${ANNOTATIONS_DIST_DIR:-$ROOT_DIR/dist}"

usage() {
  cat <<'EOF'
Build a local Annotations desktop release archive.

Usage:
  scripts/package_installed_apps.sh linux
  scripts/package_installed_apps.sh macos

The command packages an existing Flutter release build. It does not build,
sign, publish, or install the application.

Optional build-path overrides for isolated checks:
  ANNOTATIONS_LINUX_BUNDLE
  ANNOTATIONS_MACOS_APP
  ANNOTATIONS_DIST_DIR
EOF
}

fail() {
  printf 'package_installed_apps: %s\n' "$*" >&2
  exit 2
}

validate_macos_links() {
  local app="$1" link target relative parent component depth
  local -a components
  while IFS= read -r -d '' link; do
    target="$(readlink "$link")"
    [[ -n "$target" && "$target" != /* && "$target" != *\\* && ! "$target" =~ [^[:print:]] ]] || fail "macOS app contains an unsafe symbolic link"
    relative="${link#"$app"/}"
    if [[ "$relative" == */* ]]; then parent="${relative%/*}"; else parent=""; fi
    depth=0
    if [[ -n "$parent" ]]; then
      IFS='/' read -r -a components <<< "$parent"
      depth="${#components[@]}"
    fi
    IFS='/' read -r -a components <<< "$target"
    for component in "${components[@]}"; do
      case "$component" in
        ''|.) ;;
        ..) (( depth > 0 )) || fail "macOS app symbolic link escapes its bundle"; depth=$((depth - 1)) ;;
        *) depth=$((depth + 1)) ;;
      esac
    done
  done < <(find -P "$app" -type l -print0)
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
platform="$1"
case "$platform" in
  linux|macos) ;;
  -h|--help) usage; exit 0 ;;
  *) fail "platform must be linux or macos" ;;
esac

raw_version="$(awk '$1 == "version:" { print $2; exit }' "$APP_DIR/pubspec.yaml")"
version="${raw_version%%+*}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail "invalid app version in apps/local/pubspec.yaml"
mkdir -p "$DIST_DIR"
stage="$(mktemp -d "${TMPDIR:-/tmp}/annotations-package.XXXXXX")"
tmp_artifact=""
trap 'rm -rf "$stage"; [[ -z "$tmp_artifact" ]] || rm -f "$tmp_artifact"' EXIT

case "$platform" in
  linux)
    [[ "$(uname -s)" == Linux ]] || fail "Linux archives must be packaged on Linux"
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) asset="annotations-linux-x64.tar.gz" ;;
      *) fail "unsupported Linux architecture: $arch" ;;
    esac
    bundle="${ANNOTATIONS_LINUX_BUNDLE:-$APP_DIR/build/linux/x64/release/bundle}"
    [[ -x "$bundle/annotations_local" ]] || fail "release bundle is missing annotations_local"
    [[ -d "$bundle/data/flutter_assets" ]] || fail "release bundle is missing Flutter assets"
    [[ -f "$bundle/data/native/annotations.png" ]] || fail "release bundle is missing the Linux app icon"
    [[ -f "$bundle/data/native/annotations.desktop.in" ]] || fail "release bundle is missing the Linux desktop entry template"
    if find -P "$bundle" ! -type f ! -type d -print -quit | grep -q .; then
      fail "Linux bundle contains a link or special file"
    fi
    mkdir "$stage/bundle"
    cp -a "$bundle/." "$stage/bundle/"
    printf '%s\n' "$version" > "$stage/VERSION"
    tmp_artifact="$DIST_DIR/$asset.tmp"
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
      -czf "$tmp_artifact" -C "$stage" bundle VERSION
    mv "$tmp_artifact" "$DIST_DIR/$asset"
    tmp_artifact=""
    ;;
  macos)
    [[ "$(uname -s)" == Darwin ]] || fail "macOS archives must be packaged on macOS"
    command -v ditto >/dev/null 2>&1 || fail "ditto is required to preserve the app bundle"
    arch="$(uname -m)"
    case "$arch" in
      arm64) asset="annotations-macos-arm64.zip" ;;
      x86_64) asset="annotations-macos-x64.zip" ;;
      *) fail "unsupported macOS architecture: $arch" ;;
    esac
    app="${ANNOTATIONS_MACOS_APP:-$APP_DIR/build/macos/Build/Products/Release/Annotations.app}"
    [[ -f "$app/Contents/Info.plist" ]] || fail "release app bundle is missing Info.plist"
    macos_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
    validate_macos_executable "$app" "$macos_executable" || fail "release app bundle is missing its Annotations executable"
    validate_macos_links "$app"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$bundle_id" == com.asodya.annotations ]] || fail "release app bundle has an unexpected bundle identifier"
    tmp_artifact="$DIST_DIR/$asset.tmp"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$tmp_artifact"
    mv "$tmp_artifact" "$DIST_DIR/$asset"
    tmp_artifact=""
    ;;
esac

sum_tmp="$DIST_DIR/SHA256SUMS.tmp"
tmp_artifact="$sum_tmp"
write_package_checksums "$DIST_DIR" "$platform" > "$sum_tmp"
mv "$sum_tmp" "$DIST_DIR/SHA256SUMS"
tmp_artifact=""
printf 'Packaged %s %s\n' "$asset" "$version"
