#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/build_cloudflare.sh"
python3 - "$ROOT_DIR" <<'PY'
import importlib.util, sys
from pathlib import Path
root=Path(sys.argv[1]);spec=importlib.util.spec_from_file_location('annotations_deployer', root/'scripts/cloudflare_deployer.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
module.deploy_pages_project('asodya-annotations',root/'build/web',custom_domain='annotations.asodya.com',branch='main')
PY
