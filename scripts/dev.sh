#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/dev.sh [--ui]' \
    '' \
    '  no option  Watch the complete app, incrementally rebuild, sign, and relaunch.' \
    '  --ui       Watch the mock-data Visual Lab without privacy permissions.'
}

mode='app'
if (($# > 0)); then
  case "$1" in
    --ui) mode='ui' ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
fi
if (($# > 1)); then
  usage >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
app_bundle="$repo_root/.afterray-dev/AfterRay.app"
visual_lab_bin="$repo_root/.build/debug/afterray-visual-lab"
visual_lab_pid=''

mkdir -p "$repo_root/.afterray-dev"

watch_paths=(
  "$repo_root/Package.swift"
  "$repo_root/Makefile"
  "$repo_root/swift"
)
if [[ "$mode" == 'app' ]]; then
  watch_paths+=(
    "$repo_root/Cargo.toml"
    "$repo_root/Cargo.lock"
    "$repo_root/apps/AfterRay"
    "$repo_root/apps/AfterRayCaptureShim"
    "$repo_root/apps/AfterRayNativeModelWorker"
    "$repo_root/apps/AfterRayMlxVlmWorker"
    "$repo_root/crates"
    "$repo_root/scripts/run-v0.sh"
  )
else
  watch_paths+=(
    "$repo_root/apps/AfterRayVisualLab"
    "$repo_root/swift/AfterRayMockData"
  )
fi

source_fingerprint() {
  find "${watch_paths[@]}" -type f \
    \( -name '*.swift' -o -name '*.rs' -o -name '*.toml' -o -name '*.lock' \
       -o -name '*.plist' -o -name '*.py' -o -name '*.sh' -o -name 'Makefile' \) \
    -exec stat -f '%m:%z:%N' {} + 2>/dev/null \
    | shasum -a 256 \
    | awk '{print $1}'
}

stop_visual_lab() {
  if [[ -n "$visual_lab_pid" ]] && kill -0 "$visual_lab_pid" 2>/dev/null; then
    kill "$visual_lab_pid" 2>/dev/null || true
    wait "$visual_lab_pid" 2>/dev/null || true
  fi
  visual_lab_pid=''
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  stop_visual_lab
  if [[ "$mode" == 'app' ]]; then
    "$script_dir/stop-dev.sh" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

build_and_launch_app() {
  if ! "$script_dir/run-v0.sh" --build-only; then
    printf '%s\n' 'Build failed. The previous AfterRay instance remains available.' >&2
    return 1
  fi
  open -n "$app_bundle"
  printf '%s\n' 'AfterRay relaunched. Watching for changes…'
}

build_and_launch_ui() {
  if ! swift build \
    --package-path "$repo_root" \
    --configuration debug \
    --product afterray-visual-lab
  then
    printf '%s\n' 'Visual Lab build failed. The previous instance remains available.' >&2
    return 1
  fi
  stop_visual_lab
  "$visual_lab_bin" >"$repo_root/.afterray-dev/visual-lab.log" 2>&1 &
  visual_lab_pid=$!
  printf '%s\n' 'Visual Lab relaunched. Watching for changes…'
}

rebuild() {
  if [[ "$mode" == 'app' ]]; then
    build_and_launch_app
  else
    build_and_launch_ui
  fi
}

printf '%s\n' \
  "AfterRay development loop: $mode" \
  'Press Control-C to stop the watcher, app, and daemon.'

rebuild || true
previous_fingerprint="$(source_fingerprint)"

while true; do
  sleep 0.4
  current_fingerprint="$(source_fingerprint)"
  [[ "$current_fingerprint" == "$previous_fingerprint" ]] && continue

  # Wait for editors that save through multiple rename/write operations.
  while true; do
    previous_fingerprint="$current_fingerprint"
    sleep 0.25
    current_fingerprint="$(source_fingerprint)"
    [[ "$current_fingerprint" == "$previous_fingerprint" ]] && break
  done

  printf '\n%s\n' 'Source change detected. Rebuilding…'
  rebuild || true
  previous_fingerprint="$(source_fingerprint)"
done
