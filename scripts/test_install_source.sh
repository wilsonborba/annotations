#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(uname -s)" == Linux ]] || { printf 'fixture runs on Linux only\n' >&2; exit 77; }
work="$(mktemp -d "${TMPDIR:-/tmp}/annotations-installer-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
release="$work/release"
data_home="$work/data home"
bin_home="$work/bin tools"
mkdir -p "$release" "$work/tmp" "$work/home" "$data_home" "$bin_home"

# Verify the checked-in native icon catalogs and Linux bundle wiring without a
# platform build or host install.
python3 - "$ROOT_DIR" <<'PY'
import hashlib
import json
import struct
import sys
from pathlib import Path

root = Path(sys.argv[1]) / 'apps/local'
expected_hashes = {
    'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': '8b5ded55794bfaa3970b08728f1043bd6488cdf954a0367b4c3c4f0f5c8ac345',
    'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png': 'f8b32ffb5eaf1bb8496afd04deba6f8f25a3755ec7bd524b7ad829e6fe551747',
    'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png': 'e2e0485536fe293aa12bc19aef22946032916e4c09ed335947315cf44fcb67e2',
    'linux/annotations.png': 'af4abc2033f25b495dc2edb821d4165c9dcb33b312820c751ff7b3f4ddbaff7f',
}

def dimensions(path):
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        raise SystemExit(f'not a PNG: {path}')
    return struct.unpack('>II', data[16:24])

for relative, digest in expected_hashes.items():
    path = root / relative
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f'unexpected native brand asset bytes: {relative}')
    width, height = dimensions(path)
    if width != height:
        raise SystemExit(f'native icon is not square: {relative}')

for catalog in (
    root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
    root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
):
    for image in json.loads(catalog.read_text())['images']:
        filename = image.get('filename')
        if not filename:
            continue
        path = catalog.parent / filename
        width, height = dimensions(path)
        expected = round(float(image['size'].split('x')[0]) * float(image['scale'].removesuffix('x')))
        if (width, height) != (expected, expected):
            raise SystemExit(f'wrong icon dimensions for {path}: {width}x{height}, expected {expected}x{expected}')

manifest = (root / 'android/app/src/main/AndroidManifest.xml').read_text()
if 'android:icon="@mipmap/ic_launcher"' not in manifest or 'android:roundIcon="@mipmap/ic_launcher_round"' not in manifest:
    raise SystemExit('Android manifest does not select both branded launcher icons')
cmake = (root / 'linux/CMakeLists.txt').read_text()
runner = (root / 'linux/runner/my_application.cc').read_text()
if 'annotations.png' not in cmake or 'annotations.desktop.in' not in cmake or 'ASODYA_ANNOTATIONS_ICON' not in runner:
    raise SystemExit('Linux native icon is not bundled and used by the GTK window')
PY

package_release() {
  local marker="$1" tree="$work/package-tree" dist="$work/dist"
  rm -rf "$tree" "$dist"
  mkdir -p "$tree/data/flutter_assets" "$tree/data/native" "$dist"
  printf '#!/bin/sh\n# fixture %s\n' "$marker" > "$tree/annotations_local"
  chmod 0755 "$tree/annotations_local"
  printf 'fixture\n' > "$tree/data/flutter_assets/fixture"
  cp "$ROOT_DIR/apps/local/linux/annotations.png" "$tree/data/native/annotations.png"
  cp "$ROOT_DIR/apps/local/linux/annotations.desktop.in" "$tree/data/native/annotations.desktop.in"
  env TMPDIR="$work/tmp" ANNOTATIONS_LINUX_BUNDLE="$tree" ANNOTATIONS_DIST_DIR="$dist" \
    bash "$ROOT_DIR/scripts/package_installed_apps.sh" linux >/dev/null
  cp "$dist/annotations-linux-x64.tar.gz" "$release/"
  cp "$dist/SHA256SUMS" "$release/"
}

run_installer() {
  env HOME="$work/home" XDG_DATA_HOME="$data_home" XDG_BIN_HOME="$bin_home" \
    TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
    bash -c 'set -o pipefail; cat "$1" | bash -s -- "${@:2}"' \
      _ "$ROOT_DIR/install.sh" "$@"
}

run_installer_with_launcher_swap_failure() {
  env HOME="$work/home" XDG_DATA_HOME="$data_home" XDG_BIN_HOME="$bin_home" \
    TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
    INJECT_LAUNCHER_MV_FAILURE=1 FAIL_MV_MARKER="$work/failing-bin/fired" \
    PATH="$work/failing-bin:$PATH" \
    bash -c 'set -o pipefail; cat "$1" | bash -s -- "${@:2}"' \
      _ "$ROOT_DIR/install.sh" "$@"
}

run_installer_with_desktop_swap_failure() {
  env HOME="$work/home" XDG_DATA_HOME="$data_home" XDG_BIN_HOME="$bin_home" \
    TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
    INJECT_DESKTOP_MV_FAILURE=1 FAIL_MV_MARKER="$work/failing-bin/desktop-fired" \
    PATH="$work/failing-bin:$PATH" \
    bash -c 'set -o pipefail; cat "$1" | bash -s -- "${@:2}"' \
      _ "$ROOT_DIR/install.sh" "$@"
}

validate_macos_archive() {
  (
    source "$ROOT_DIR/install.sh"
    archive="$1"
    validate_macos_archive
  )
}

help_output="$(cat "$ROOT_DIR/install.sh" | bash -s -- --help)"
grep -q 'Usage:' <<< "$help_output"
grep -q 'does not need administrator rights' <<< "$help_output"

package_release first
run_installer
grep -q 'fixture first' "$data_home/annotations/current/bundle/annotations_local"
[[ -x "$bin_home/annotations" ]]
[[ -f "$data_home/applications/com.asodya.annotations.desktop" ]]
grep -q '^Exec=".*/annotations"$' "$data_home/applications/com.asodya.annotations.desktop"
expected_icon="${data_home// /\\s}/annotations/current/bundle/data/native/annotations.png"
grep -Fxq "Icon=$expected_icon" "$data_home/applications/com.asodya.annotations.desktop"
[[ -f "$data_home/annotations/current/bundle/data/native/annotations.png" ]]
grep -q 'ASODYA_ANNOTATIONS_ICON=.*bundle/data/native/annotations.png' "$bin_home/annotations"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$data_home/applications/com.asodya.annotations.desktop"
fi

package_release second
run_installer
grep -q 'fixture second' "$data_home/annotations/current/bundle/annotations_local"

# A failed atomic launcher swap must report failure and restore the old app.
launcher_before="$(sha256sum "$bin_home/annotations" | awk '{print $1}')"
app_before="$(sha256sum "$data_home/annotations/current/bundle/annotations_local" | awk '{print $1}')"
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
[[ "$(sha256sum "$data_home/annotations/current/bundle/annotations_local" | awk '{print $1}')" == "$app_before" ]]
[[ "$(sha256sum "$bin_home/annotations" | awk '{print $1}')" == "$launcher_before" ]]
[[ -z "$(find "$data_home/annotations" -maxdepth 1 -name '.previous.*' -print -quit)" ]]

# A failed desktop-entry swap must leave the prior app and menu registration intact.
desktop_before="$(sha256sum "$data_home/applications/com.asodya.annotations.desktop" | awk '{print $1}')"
launcher_before="$(sha256sum "$bin_home/annotations" | awk '{print $1}')"
app_before="$(sha256sum "$data_home/annotations/current/bundle/annotations_local" | awk '{print $1}')"
package_release fourth
cat > "$work/failing-bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${INJECT_DESKTOP_MV_FAILURE:-}" == 1 && $# -eq 3 && "$1" == -f && "$3" == "$XDG_DATA_HOME/applications/com.asodya.annotations.desktop" && "$2" == "${XDG_DATA_HOME}/applications/".com.asodya.annotations.desktop.* ]]; then
  : > "$FAIL_MV_MARKER"
  exit 74
fi
exec /usr/bin/mv "$@"
EOF
chmod 0755 "$work/failing-bin/mv"
if run_installer_with_desktop_swap_failure >"$work/desktop-failure.log" 2>&1; then
  printf 'installer hid a desktop-entry swap failure\n' >&2
  exit 1
fi
[[ -f "$work/failing-bin/desktop-fired" ]]
grep -q 'could not activate the user desktop entry' "$work/desktop-failure.log"
[[ "$(sha256sum "$data_home/applications/com.asodya.annotations.desktop" | awk '{print $1}')" == "$desktop_before" ]]
[[ "$(sha256sum "$bin_home/annotations" | awk '{print $1}')" == "$launcher_before" ]]
[[ "$(sha256sum "$data_home/annotations/current/bundle/annotations_local" | awk '{print $1}')" == "$app_before" ]]
[[ -z "$(find "$data_home/annotations" -maxdepth 1 -name '.previous.*' -print -quit)" ]]

# An unowned launcher must reject an update before replacing the installed app.
printf 'keep this launcher\n' > "$bin_home/annotations"
before="$(sha256sum "$data_home/annotations/current/bundle/annotations_local" | awk '{print $1}')"
package_release fourth
if run_installer >/dev/null 2>&1; then
  printf 'installer accepted a conflicting launcher\n' >&2
  exit 1
fi
after="$(sha256sum "$data_home/annotations/current/bundle/annotations_local" | awk '{print $1}')"
[[ "$before" == "$after" ]]
grep -q 'keep this launcher' "$bin_home/annotations"

# A desktop-entry name owned by another app is preserved and blocks install.
conflict_data="$work/conflict data"
conflict_bin="$work/conflict bin"
mkdir -p "$conflict_data/applications" "$conflict_bin"
printf 'foreign desktop entry\n' > "$conflict_data/applications/com.asodya.annotations.desktop"
package_release fifth
if env HOME="$work/home" XDG_DATA_HOME="$conflict_data" XDG_BIN_HOME="$conflict_bin" \
  TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
  bash "$ROOT_DIR/install.sh" >"$work/conflict.log" 2>&1; then
  printf 'installer replaced a foreign desktop entry\n' >&2
  exit 1
fi
grep -q 'exists and is not owned by this installer' "$work/conflict.log"
grep -q 'foreign desktop entry' "$conflict_data/applications/com.asodya.annotations.desktop"
[[ ! -e "$conflict_data/annotations/current" ]]

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
mkdir -p "$tree/bundle/data/flutter_assets" "$tree/bundle/data/native"
printf '#!/bin/sh\n' > "$tree/bundle/annotations_local"
chmod 0755 "$tree/bundle/annotations_local"
cp "$ROOT_DIR/apps/local/linux/annotations.png" "$tree/bundle/data/native/annotations.png"
cp "$ROOT_DIR/apps/local/linux/annotations.desktop.in" "$tree/bundle/data/native/annotations.desktop.in"
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
if env HOME="$work/home" XDG_DATA_HOME="$work/symlink-data" XDG_BIN_HOME="$bin_home" \
  TMPDIR="$work/tmp" ANNOTATIONS_RELEASE_BASE_URL="file://$release" \
  bash "$ROOT_DIR/install.sh" >/dev/null 2>&1; then
  printf 'installer replaced a dangling current symlink\n' >&2
  exit 1
fi
[[ -L "$work/symlink-data/annotations/current" ]]
[[ ! -e "$work/outside" ]]

# Uninstall removes only this installer's marked menu and launcher entries.
rm -f "$bin_home/annotations"
package_release sixth
run_installer
[[ -f "$data_home/applications/com.asodya.annotations.desktop" ]]
env HOME="$work/home" XDG_DATA_HOME="$data_home" XDG_BIN_HOME="$bin_home" \
  bash "$ROOT_DIR/install.sh" --uninstall >/dev/null
[[ ! -e "$data_home/annotations/current" ]]
[[ ! -e "$data_home/applications/com.asodya.annotations.desktop" ]]
[[ ! -e "$bin_home/annotations" ]]

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
