#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { printf 'fixture runs on Linux only\n' >&2; exit 77; }
work="$(mktemp -d "${TMPDIR:-/tmp}/annotations-installer-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
release="$work/release"
mkdir -p "$release" "$work/tmp" "$work/home" "$work/data" "$work/bin"

package_release() {
  local marker="$1" tree="$work/package-tree" dist="$work/dist"
  rm -rf "$tree" "$dist"
  mkdir -p "$tree/data/flutter_assets" "$dist"
  printf '#!/bin/sh\n# fixture %s\n' "$marker" > "$tree/annotations_local"
  chmod 0755 "$tree/annotations_local"
  printf 'fixture\n' > "$tree/data/flutter_assets/fixture"
  env TMPDIR="$work/tmp" ANNOTATIONS_LINUX_BUNDLE="$tree" ANNOTATIONS_DIST_DIR="$dist" \
    bash "$ROOT_DIR/scripts/package_installed_apps.sh" linux >/dev/null
  cp "$dist/annotations-linux-x64.tar.gz" "$release/"
  cp "$dist/SHA256SUMS" "$release/"
}

run_installer() {
  env HOME="$work/home" XDG_DATA_HOME="$work/data" XDG_BIN_HOME="$work/bin" \
    TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
    bash "$ROOT_DIR/install.sh" "$@"
}

run_installer_with_launcher_swap_failure() {
  env HOME="$work/home" XDG_DATA_HOME="$work/data" XDG_BIN_HOME="$work/bin" \
    TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
    INJECT_LAUNCHER_MV_FAILURE=1 FAIL_MV_MARKER="$work/failing-bin/fired" \
    PATH="$work/failing-bin:$PATH" \
    bash "$ROOT_DIR/install.sh" "$@"
}

validate_macos_archive() {
  (
    source "$ROOT_DIR/install.sh"
    archive="$1"
    validate_macos_archive
  )
}

package_release first
run_installer
grep -q 'fixture first' "$work/data/annotations/current/bundle/annotations_local"
[[ -x "$work/bin/annotations" ]]

package_release second
run_installer
grep -q 'fixture second' "$work/data/annotations/current/bundle/annotations_local"

# A failed atomic launcher swap must report failure and restore the old app.
launcher_before="$(sha256sum "$work/bin/annotations" | awk '{print $1}')"
app_before="$(sha256sum "$work/data/annotations/current/bundle/annotations_local" | awk '{print $1}')"
package_release third
mkdir -p "$work/failing-bin"
cat > "$work/failing-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${INJECT_LAUNCHER_MV_FAILURE:-}" == 1 && $# -eq 3 && "$1" == -f && "$3" == "$XDG_BIN_HOME/annotations" && "$2" == "${XDG_BIN_HOME}/".annotations.* ]]; then
  : > "$FAIL_MV_MARKER"
  exit 73
fi
exec /usr/bin/mv "$@"
EOF
chmod 0755 "$work/failing-bin/mv"
if run_installer_with_launcher_swap_failure >"$work/failure.log" 2>&1; then
  printf 'installer hid a launcher swap failure\n' >&2
  exit 1
fi
[[ -f "$work/failing-bin/fired" ]]
grep -q 'could not activate the user launcher' "$work/failure.log"
[[ "$(sha256sum "$work/data/annotations/current/bundle/annotations_local" | awk '{print $1}')" == "$app_before" ]]
[[ "$(sha256sum "$work/bin/annotations" | awk '{print $1}')" == "$launcher_before" ]]
[[ -z "$(find "$work/data/annotations" -maxdepth 1 -name '.previous.*' -print -quit)" ]]

# An unowned launcher must reject an update before replacing the installed app.
printf 'keep this launcher\n' > "$work/bin/annotations"
before="$(sha256sum "$work/data/annotations/current/bundle/annotations_local" | awk '{print $1}')"
package_release fourth
if run_installer >/dev/null 2>&1; then
  printf 'installer accepted a conflicting launcher\n' >&2
  exit 1
fi
after="$(sha256sum "$work/data/annotations/current/bundle/annotations_local" | awk '{print $1}')"
[[ "$before" == "$after" ]]
grep -q 'keep this launcher' "$work/bin/annotations"

# The packager also rejects symlinks in a Linux source bundle.
ln -s "$work/outside" "$work/package-tree/escape"
if env TMPDIR="$work/tmp" ANNOTATIONS_LINUX_BUNDLE="$work/package-tree" ANNOTATIONS_DIST_DIR="$work/package-rejected" \
  bash "$ROOT_DIR/scripts/package_installed_apps.sh" linux >/dev/null 2>&1; then
  printf 'packager accepted a Linux bundle symlink\n' >&2
  exit 1
fi
[[ ! -e "$work/package-rejected/annotations-linux-x64.tar.gz" ]]

# A tar symlink is rejected before extraction and cannot escape the app root.
tree="$work/malicious"
rm -rf "$tree"
mkdir -p "$tree/bundle/data/flutter_assets"
printf '#!/bin/sh\n' > "$tree/bundle/annotations_local"
chmod 0755 "$tree/bundle/annotations_local"
ln -s "$work/outside" "$tree/bundle/escape"
tar -czf "$release/annotations-linux-x64.tar.gz" -C "$tree" bundle
digest="$(sha256sum "$release/annotations-linux-x64.tar.gz" | awk '{print $1}')"
printf '%s  annotations-linux-x64.tar.gz\n' "$digest" > "$release/SHA256SUMS"
if run_installer >/dev/null 2>&1; then
  printf 'installer accepted a tar symlink\n' >&2
  exit 1
fi
[[ ! -e "$work/outside" ]]

# A dangling current symlink is treated as occupied and is never replaced.
mkdir -p "$work/symlink-data/annotations"
ln -s "$work/outside" "$work/symlink-data/annotations/current"
if env HOME="$work/home" XDG_DATA_HOME="$work/symlink-data" XDG_BIN_HOME="$work/bin" \
  TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
  bash "$ROOT_DIR/install.sh" >/dev/null 2>&1; then
  printf 'installer replaced a dangling current symlink\n' >&2
  exit 1
fi
[[ -L "$work/symlink-data/annotations/current" ]]
[[ ! -e "$work/outside" ]]

# Exercise the macOS archive validator itself without invoking ditto/macOS.
python3 - "$work" <<'PY'
import stat
import sys
import zipfile
from pathlib import Path

root = Path(sys.argv[1])
one = root / 'valid-one.zip'
with zipfile.ZipFile(one, 'w') as z:
    info = zipfile.ZipInfo('Annotations.app/Contents/Info.plist')
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    z.writestr(info, 'fixture')

many = root / 'valid-many.zip'
with zipfile.ZipFile(many, 'w') as z:
    directory = zipfile.ZipInfo('Annotations.app/')
    directory.create_system = 3
    directory.external_attr = (stat.S_IFDIR | 0o755) << 16
    z.writestr(directory, '')
    for name in ('Annotations.app/Contents/Info.plist', 'Annotations.app/Contents/MacOS/app'):
        info = zipfile.ZipInfo(name)
        info.create_system = 3
        info.external_attr = (stat.S_IFREG | 0o755) << 16
        z.writestr(info, 'fixture')

traversal = root / 'invalid-traversal.zip'
with zipfile.ZipFile(traversal, 'w') as z:
    z.writestr('Annotations.app/Contents/../../escape', 'bad')

escaping_link = root / 'invalid-link.zip'
with zipfile.ZipFile(escaping_link, 'w') as z:
    info = zipfile.ZipInfo('Annotations.app/Contents/Frameworks/Evil')
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    z.writestr(info, '../../../../outside')
PY
validate_macos_archive "$work/valid-one.zip"
validate_macos_archive "$work/valid-many.zip"
for unsafe in "$work/invalid-traversal.zip" "$work/invalid-link.zip"; do
  if validate_macos_archive "$unsafe" >/dev/null 2>&1; then
    printf 'macOS validator accepted an unsafe archive: %s\n' "$unsafe" >&2
    exit 1
  fi
done

printf 'installer source fixture passed\n'
