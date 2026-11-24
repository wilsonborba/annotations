#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/../../scripts/build_pdf_krilla.sh" wasm
cd "$ROOT_DIR"
flutter build web --release --base-href / --no-web-resources-cdn \
  --dart-define=API_BASE_URL="${API_BASE_URL:-https://api.asodya.com/apps/annotations/v1}" \
  --dart-define=DEVELOPMENT_MODE=false \
  --dart-define=AUTH_BASE_URL="${AUTH_BASE_URL:-https://auth.asodya.com}" \
  --dart-define=APP_CONTEXT_KEY="${APP_CONTEXT_KEY:?APP_CONTEXT_KEY from the canonical .env is required for the browser login}" \
  --dart-define=BUILD_NAME="${BUILD_NAME:-1.0.0}" \
  --dart-define=BUILD_TIMESTAMP="$(TZ=Asia/Bangkok date +'%Y-%m-%d %H:%M ICT')"

cp web/_worker.js web/_routes.json build/web/
