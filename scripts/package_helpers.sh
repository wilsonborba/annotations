#!/usr/bin/env bash

validate_macos_executable() {
  local app="$1" executable="$2"
  [[ "$executable" == "Annotations" && -x "$app/Contents/MacOS/$executable" ]]
}

write_package_checksums() {
  local dist="$1" platform="$2" file output digest
  (
    cd "$dist"
    export LC_ALL=C
    shopt -s nullglob
    local files=(annotations-*)
    ((${#files[@]} > 0)) || return 1
    for file in "${files[@]}"; do
      [[ -f "$file" && ! -L "$file" ]] || continue
      if [[ "$platform" == macos ]]; then
        output="$(shasum -a 256 "$file")" || return 1
      elif command -v sha256sum >/dev/null 2>&1; then
        output="$(sha256sum "$file")" || return 1
      else
        output="$(shasum -a 256 "$file")" || return 1
      fi
      digest="${output%% *}"
      [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
      printf '%s  %s\n' "$digest" "$file"
    done
  )
}
