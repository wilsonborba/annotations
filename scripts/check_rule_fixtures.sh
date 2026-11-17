#!/usr/bin/env bash
# Compare the app copy of the editor rule fixtures with the canonical set in
# annotations_api at a pinned commit. Fails when a file differs, is missing or
# is extra. Update PIN and the copy together when the backend fixtures change.
#
# Usage: scripts/check_rule_fixtures.sh [fixture_dir]
#   ANNOTATIONS_API_DIR  local annotations_api clone (default: ../annotations_api
#                        next to this repository). The pinned commit is fetched
#                        from its origin if it is not present.
set -euo pipefail

PIN=5317abb5e5ec5f68bdf42d84e18a8c8d7440ade6
SOURCE=tests/fixtures/editor_rules

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
copy="${1:-$root/common/annotations_shared/test/fixtures/editor_rules}"
api="${ANNOTATIONS_API_DIR:-$root/../annotations_api}"

if [[ ! -d "$api/.git" ]]; then
  echo "annotations_api clone not found at $api (set ANNOTATIONS_API_DIR)" >&2
  exit 2
fi
if ! git -C "$api" cat-file -e "$PIN^{commit}" 2>/dev/null; then
  git -C "$api" fetch --quiet origin "$PIN"
fi

failed=0
expected="$(git -C "$api" ls-tree --name-only "$PIN" "$SOURCE/" | sed 's#.*/##' | sort)"
actual="$(cd "$copy" && find . -maxdepth 1 -type f -printf '%f\n' | sort)"

while read -r name; do
  [[ -z "$name" ]] && continue
  if [[ ! -f "$copy/$name" ]]; then
    echo "missing: $name"
    failed=1
  elif ! cmp -s <(git -C "$api" show "$PIN:$SOURCE/$name") "$copy/$name"; then
    echo "differs: $name"
    failed=1
  fi
done <<< "$expected"

while read -r name; do
  [[ -z "$name" ]] && continue
  if ! grep -qxF "$name" <<< "$expected"; then
    echo "extra: $name"
    failed=1
  fi
done <<< "$actual"

if [[ "$failed" -ne 0 ]]; then
  echo "Rule fixtures differ from annotations_api $PIN" >&2
  exit 1
fi
echo "Rule fixtures match annotations_api $PIN ($(wc -l <<< "$expected") files)"
