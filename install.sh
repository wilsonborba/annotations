#!/usr/bin/env bash
set -euo pipefail

APP_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/annotations"
BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
DESKTOP_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_HOME/com.asodya.annotations.desktop"
MAC_APP_HOME="$HOME/Applications"
RELEASE_BASE="${ANNOTATIONS_RELEASE_BASE_URL:-https://github.com/wilsonborba/annotations/releases/latest/download}"
PLATFORM=""
ASSET=""
tmp=""
install_stage=""
launcher_tmp=""
desktop_tmp=""
launcher_backup=""

cleanup() {
  [[ -z "$install_stage" ]] || rm -rf "$install_stage"
  [[ -z "$launcher_tmp" ]] || rm -f "$launcher_tmp"
  [[ -z "$desktop_tmp" ]] || rm -f "$desktop_tmp"
  [[ -z "$launcher_backup" ]] || rm -f "$launcher_backup"
  [[ -z "$tmp" ]] || rm -rf "$tmp"
}
trap cleanup EXIT

say() { printf '[annotations-install] %s\n' "$*"; }
fail() { printf '[annotations-install] ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Annotations user installer

Usage:
  bash install.sh
  bash install.sh --uninstall

Run the installer again to update. It installs only in the current user's
directories and does not need administrator rights. The macOS app bundle is
installed in ~/Applications. Linux launches from ~/.local/bin/annotations.
EOF
}

detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Linux:x86_64|Linux:amd64) PLATFORM=linux; ASSET=annotations-linux-x64.tar.gz ;;
    Darwin:arm64) PLATFORM=macos; ASSET=annotations-macos-arm64.zip ;;
    Darwin:x86_64) PLATFORM=macos; ASSET=annotations-macos-x64.zip ;;
    *) fail "unsupported platform: $os $arch" ;;
  esac
}

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

verify_asset() {
  local archive="$1" sums="$2" expected actual
  expected="$(awk -v name="$ASSET" '$2 == name {print $1}' "$sums")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || fail "checksum entry for $ASSET is missing or invalid"
  actual="$(checksum "$archive")"
  expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  actual="$(printf '%s' "$actual" | tr 'A-F' 'a-f')"
  [[ "$actual" == "$expected" ]] || fail "checksum mismatch for $ASSET"
}

prepare_launcher() {
  local target="$BIN_HOME/annotations"
  if [[ -e "$target" || -L "$target" ]] && { [[ -L "$target" ]] || ! grep -q 'ASODYA_ANNOTATIONS_USER_LAUNCHER' "$target"; }; then
    fail "$target exists and is not owned by this installer"
  fi
  mkdir -p "$BIN_HOME"
  launcher_tmp="$(mktemp "$BIN_HOME/.annotations.XXXXXX")"
  if [[ "$PLATFORM" == linux ]]; then
    cat > "$launcher_tmp" <<'EOF'
#!/usr/bin/env bash
# ASODYA_ANNOTATIONS_USER_LAUNCHER
set -euo pipefail
export ASODYA_ANNOTATIONS_ICON="${XDG_DATA_HOME:-$HOME/.local/share}/annotations/current/bundle/data/native/annotations.png"
exec "${XDG_DATA_HOME:-$HOME/.local/share}/annotations/current/bundle/annotations_local" "$@"
EOF
  else
    cat > "$launcher_tmp" <<'EOF'
#!/usr/bin/env bash
# ASODYA_ANNOTATIONS_USER_LAUNCHER
set -euo pipefail
exec open -a "$HOME/Applications/Annotations.app" --args "$@"
EOF
  fi
  chmod 0755 "$launcher_tmp"
}

desktop_exec_arg() {
  local value="$1" char escaped='"' index
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *%* ]] || return 1
  for ((index = 0; index < ${#value}; index++)); do
    char="${value:index:1}"
    case "$char" in
      \\) escaped+='\\\\' ;;
      '"') escaped+='\\' ; escaped+="$char" ;;
      '$'|'`') escaped+='\\'; escaped+="$char" ;;
      *) escaped+="$char" ;;
    esac
  done
  escaped+='"'
  printf '%s' "$escaped"
}

desktop_icon_value() {
  local value="$1" char escaped='' index
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  for ((index = 0; index < ${#value}; index++)); do
    char="${value:index:1}"
    case "$char" in
      ' ') escaped+='\s' ;;
      \\) escaped+='\\' ;;
      *) escaped+="$char" ;;
    esac
  done
  printf '%s' "$escaped"
}

prepare_desktop_entry() {
  local template="$1" launcher_exec icon_path icon_value line
  if [[ -e "$DESKTOP_FILE" || -L "$DESKTOP_FILE" ]] && {
    [[ -L "$DESKTOP_FILE" ]] || ! grep -q 'ASODYA_ANNOTATIONS_USER_DESKTOP' "$DESKTOP_FILE"
  }; then
    fail "$DESKTOP_FILE exists and is not owned by this installer"
  fi
  [[ -f "$template" && ! -L "$template" ]] || fail "release bundle is missing the Linux desktop entry template"
  # Local GIO treats raw percent as a field code and rejects the spec's %%
  # executable-path form, so reject it before publishing a broken launcher.
  [[ "$BIN_HOME/annotations" != *%* ]] || fail "the desktop launcher cannot safely encode a percent character in its executable path"
  launcher_exec="$(desktop_exec_arg "$BIN_HOME/annotations")" || fail "desktop launcher path contains an unsupported line break"
  icon_path="$APP_HOME/current/bundle/data/native/annotations.png"
  icon_value="$(desktop_icon_value "$icon_path")" || fail "desktop icon path contains an unsupported line break"
  mkdir -p "$DESKTOP_HOME"
  desktop_tmp="$(mktemp "$DESKTOP_HOME/.com.asodya.annotations.desktop.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(replace_all "$line" '@ANNOTATIONS_LAUNCHER_EXEC@' "$launcher_exec")"
    line="$(replace_all "$line" '@ANNOTATIONS_ICON@' "$icon_value")"
    printf '%s\n' "$line"
  done < "$template" > "$desktop_tmp"
  if grep -q '@ANNOTATIONS_' "$desktop_tmp"; then
    fail "release bundle has an unresolved Linux desktop entry placeholder"
  fi
}

replace_all() {
  local input="$1" token="$2" replacement="$3" output=""
  while [[ "$input" == *"$token"* ]]; do
    output+="${input%%"$token"*}$replacement"
    input="${input#*"$token"}"
  done
  printf '%s%s' "$output" "$input"
}

activate_launcher() {
  local target="$BIN_HOME/annotations"
  if ! mv -f "$launcher_tmp" "$target"; then
    return 1
  fi
  launcher_tmp=""
}

activate_desktop_entry() {
  if ! mv -f "$desktop_tmp" "$DESKTOP_FILE"; then
    return 1
  fi
  desktop_tmp=""
}

uninstall() {
  local target="$BIN_HOME/annotations"
  case "$(uname -s)" in
    Linux)
      [[ ! -L "$APP_HOME/current" ]] || fail "refusing to remove a symbolic link at the application path"
      if [[ -e "$APP_HOME/current" && ! -f "$APP_HOME/current/.asodya-installed" ]]; then
        fail "refusing to remove an unmarked application directory"
      fi
      rm -rf "$APP_HOME/current"
      if [[ -f "$DESKTOP_FILE" && ! -L "$DESKTOP_FILE" ]] && grep -q 'ASODYA_ANNOTATIONS_USER_DESKTOP' "$DESKTOP_FILE"; then
        rm -f "$DESKTOP_FILE"
      fi
      ;;
    Darwin)
      local app="$MAC_APP_HOME/Annotations.app" bundle_id
      [[ ! -L "$app" ]] || fail "refusing to remove a symbolic link at the application path"
      if [[ -f "$app/Contents/Info.plist" ]]; then
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
        [[ "$bundle_id" == com.asodya.annotations ]] || fail "refusing to remove an app with a different bundle identifier"
        rm -rf "$app"
      fi
      ;;
    *) fail "unsupported operating system" ;;
  esac
  if [[ -f "$target" ]] && grep -q 'ASODYA_ANNOTATIONS_USER_LAUNCHER' "$target"; then
    rm -f "$target"
  fi
  rmdir "$APP_HOME" 2>/dev/null || true
  say "Removed the Annotations app installed for this user."
}

install_linux() {
  local root="$APP_HOME" stage="$APP_HOME/.stage.$$" previous="$APP_HOME/.previous.$$"
  local prior_launcher="$BIN_HOME/annotations" had_launcher=0
  # Check before creating the app root, stage, or launcher temporary.
  [[ "$prior_launcher" != *%* ]] || fail "the desktop launcher cannot safely encode a percent character in its executable path"
  mkdir -p "$root"
  [[ ! -L "$root/current" ]] || fail "refusing to replace a symbolic link at the application path"
  if [[ -e "$root/current" && ! -d "$root/current" ]]; then fail "$root/current is not a directory"; fi
  if [[ -e "$root/current" && ! -f "$root/current/.asodya-installed" ]]; then
    fail "refusing to replace an unmarked application directory"
  fi
  [[ ! -e "$previous" && ! -L "$previous" ]] || fail "stale installation backup exists at $previous"
  install_stage="$stage"
  mkdir "$stage"
  tar -tvzf "$archive" | while IFS= read -r entry; do
    local kind="${entry:0:1}" member
    [[ "$kind" == "-" || "$kind" == "d" ]] || fail "links and special files are not allowed in release archives"
    read -r _ _ _ _ _ member <<< "$entry"
    [[ -n "$member" && ! "$member" =~ [^[:print:]] ]] || fail "unsupported path in release archive"
    case "$member" in
      /*|../*|*/../*|*/..|*/./*|*/.|*//* ) fail "unsafe path in release archive" ;;
      bundle/*|VERSION) ;;
      *) fail "unexpected path in release archive: $member" ;;
    esac
  done
  prepare_launcher
  if [[ -e "$prior_launcher" ]]; then
    had_launcher=1
    launcher_backup="$(mktemp "$BIN_HOME/.annotations.previous.XXXXXX")"
    cp -p "$prior_launcher" "$launcher_backup"
  fi
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$stage"
  [[ -x "$stage/bundle/annotations_local" && -d "$stage/bundle/data/flutter_assets" ]] || fail "release archive is incomplete"
  [[ -f "$stage/bundle/data/native/annotations.png" ]] || fail "release archive is missing the Linux app icon"
  prepare_desktop_entry "$stage/bundle/data/native/annotations.desktop.in"
  : > "$stage/.asodya-installed"
  if [[ -e "$root/current" ]]; then mv "$root/current" "$previous"; fi
  if ! mv "$stage" "$root/current"; then
    [[ ! -e "$previous" ]] || mv "$previous" "$root/current"
    fail "could not activate the local app bundle"
  fi
  PLATFORM=linux
  if ! activate_launcher; then
    rm -rf "$root/current"
    [[ ! -e "$previous" ]] || mv "$previous" "$root/current"
    fail "could not activate the user launcher"
  fi
  if ! activate_desktop_entry; then
    rm -rf "$root/current"
    if [[ -e "$previous" ]]; then
      mv "$previous" "$root/current"
    fi
    if (( had_launcher )); then
      if ! mv -f "$launcher_backup" "$prior_launcher"; then
        fail "could not restore the previous user launcher"
      fi
      launcher_backup=""
    elif [[ -f "$prior_launcher" ]] && grep -q 'ASODYA_ANNOTATIONS_USER_LAUNCHER' "$prior_launcher"; then
      rm -f "$prior_launcher"
    fi
    fail "could not activate the user desktop entry"
  fi
  if [[ -n "$launcher_backup" ]]; then
    rm -f "$launcher_backup"
    launcher_backup=""
  fi
  rm -rf "$previous"
  install_stage=""
}

validate_macos_archive() {
  command -v zipinfo >/dev/null 2>&1 || fail "zipinfo is required to validate the macOS app archive"
  command -v unzip >/dev/null 2>&1 || fail "unzip is required to validate the macOS app archive"
  zipinfo -l "$archive" | while IFS= read -r entry; do
    case "$entry" in
      Archive:*|"Zip file size:"*|'') continue ;;
    esac
    if [[ "$entry" =~ ^[0-9]+[[:space:]]files?, ]]; then continue; fi
    local kind="${entry:0:1}" member size
    [[ "$kind" == "-" || "$kind" == "d" || "$kind" == "l" ]] || fail "special or unknown file type in macOS release archive"
    read -r _ _ _ size _ _ _ _ _ member <<< "$entry"
    [[ -n "$member" && ! "$member" =~ [^[:print:]] ]] || fail "unsupported path in macOS release archive"
    case "$member" in
      /*|../*|*/../*|*/..|*/./*|*/.|*//*|*\\*) fail "unsafe path in macOS release archive" ;;
      Annotations.app|Annotations.app/*|__MACOSX/._Annotations.app|__MACOSX/Annotations.app/*) ;;
      *) fail "unexpected path in macOS release archive: $member" ;;
    esac
    if [[ "$kind" == l ]]; then
      [[ "$member" == Annotations.app/* ]] || fail "resource-fork entries may not be links"
      local target parent depth component relative
      local -a components
      [[ "$size" =~ ^[0-9]+$ ]] && (( 10#$size <= 4096 )) || fail "symbolic link target is too large"
      target="$(unzip -p "$archive" "$member")"
      [[ -n "$target" && ${#target} -le 4096 && ! "$target" =~ [^[:print:]] && "$target" != /* && "$target" != *\\* ]] || fail "unsafe symbolic link in macOS release archive"
      relative="${member#Annotations.app/}"
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
          ..) (( depth > 0 )) || fail "symbolic link escapes Annotations.app"; depth=$((depth - 1)) ;;
          *) depth=$((depth + 1)) ;;
        esac
      done
    fi
  done
}

install_macos() {
  local stage="$MAC_APP_HOME/.Annotations.stage.$$" app="$MAC_APP_HOME/Annotations.app" previous="$MAC_APP_HOME/.Annotations.previous.$$" bundle_id
  command -v ditto >/dev/null 2>&1 || fail "ditto is required to extract the macOS app"
  mkdir -p "$MAC_APP_HOME"
  [[ ! -L "$app" ]] || fail "refusing to replace a symbolic link at the application path"
  [[ ! -e "$previous" && ! -L "$previous" ]] || fail "stale installation backup exists at $previous"
  install_stage="$stage"
  mkdir "$stage"
  validate_macos_archive
  prepare_launcher
  ditto -x -k "$archive" "$stage"
  [[ -f "$stage/Annotations.app/Contents/Info.plist" ]] || fail "release archive is missing Annotations.app"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Annotations.app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle_id" == com.asodya.annotations ]] || fail "release app has an unexpected bundle identifier"
  if [[ -e "$app" ]]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$bundle_id" == com.asodya.annotations ]] || fail "refusing to replace an app with a different bundle identifier"
    mv "$app" "$previous"
  fi
  if ! mv "$stage/Annotations.app" "$app"; then
    [[ ! -e "$previous" ]] || mv "$previous" "$app"
    fail "could not activate the local macOS app"
  fi
  PLATFORM=macos
  if ! rm -rf "$stage"; then
    rm -rf "$app"
    [[ ! -e "$previous" ]] || mv "$previous" "$app"
    fail "could not clean the macOS staging directory"
  fi
  if ! activate_launcher; then
    rm -rf "$app"
    [[ ! -e "$previous" ]] || mv "$previous" "$app"
    fail "could not activate the user launcher"
  fi
  rm -rf "$previous"
  install_stage=""
}

if [[ -n "${BASH_SOURCE[0]-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

[[ $# -le 1 ]] || { usage >&2; exit 2; }
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --uninstall) uninstall; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v curl >/dev/null 2>&1 || fail "curl is required"
detect_platform
tmp="$(mktemp -d "${TMPDIR:-/tmp}/annotations-install.XXXXXX")"
archive="$tmp/$ASSET"
sums="$tmp/SHA256SUMS"
curl --fail --location --silent --show-error "$RELEASE_BASE/$ASSET" -o "$archive"
curl --fail --location --silent --show-error "$RELEASE_BASE/SHA256SUMS" -o "$sums"
verify_asset "$archive" "$sums"
say "Checksum verified for $ASSET."
if [[ "$PLATFORM" == linux ]]; then
  install_linux
else
  install_macos
fi
say "Installation complete. Run annotations to open the app."
