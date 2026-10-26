#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
flutter build web --release --base-href / --no-web-resources-cdn \
  --dart-define=API_BASE_URL="${API_BASE_URL:-https://api.asodya.com/apps/annotations/v1}" \
  --dart-define=DEVELOPMENT_MODE=false \
  --dart-define=BUILD_NAME="${BUILD_NAME:-1.0.0}" \
  --dart-define=BUILD_TIMESTAMP="$(TZ=Asia/Bangkok date +'%Y-%m-%d %H:%M ICT')"
