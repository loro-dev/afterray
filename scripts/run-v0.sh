#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/run-v0.sh [--build-only | --daemon-only] [--ephemeral]' \
    '' \
    '  no option       Build everything, start afterrayd, then run the Swift app.' \
    '  --build-only    Compile the capture shim, Rust workspace, and Swift app.' \
    '  --daemon-only   Build and run afterrayd without opening the Swift app.' \
    '  --ephemeral     Use a throwaway vault instead of .afterray/v0-data.' \
    '' \
    'This script never downloads models. The app records automatically after permission approval.'
}

mode='app'
ephemeral='false'
while (($# > 0)); do
  case "$1" in
    --build-only)
      if [[ "$mode" != 'app' ]]; then
        printf '%s\n' '--build-only and --daemon-only cannot be combined' >&2
        exit 64
      fi
      mode='build'
      ;;
    --daemon-only)
      if [[ "$mode" != 'app' ]]; then
        printf '%s\n' '--build-only and --daemon-only cannot be combined' >&2
        exit 64
      fi
      mode='daemon'
      ;;
    --ephemeral)
      ephemeral='true'
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
capture_package="$repo_root/apps/AfterRayCaptureShim"
capture_shim="$capture_package/.build/release/AfterRayCaptureShim"
daemon_bin="$repo_root/target/release/afterrayd"
cli_bin="$repo_root/target/release/afterray"
model_worker="$repo_root/target/release/afterray-model-worker"
app_bin="$repo_root/.build/debug/afterray-app"
native_model_worker="$repo_root/.build/release/afterray-native-model-worker"
mlx_model_worker="$repo_root/.build/release/afterray-mlx-vlm-worker"
app_bundle="$repo_root/.afterray-dev/AfterRay.app"
swift_cache="$repo_root/.afterray-dev/swift-cache"

resolve_codesign_identity() {
  if [[ -n "${AFTERRAY_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$AFTERRAY_CODESIGN_IDENTITY"
    return
  fi

  local identities
  local line
  local prefix
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  for prefix in 'Apple Development' 'Developer ID Application'; do
    while IFS= read -r line; do
      [[ "$line" == *\"$prefix:* ]] || continue
      line="${line#*\"}"
      printf '%s\n' "${line%%\"*}"
      return
    done <<<"$identities"
  done

  printf '%s\n' '-'
}

stop_development_processes() {
  local executable
  local pid
  local -a pids=()
  for executable in \
    "$app_bundle/Contents/MacOS/AfterRay" \
    "$app_bundle/Contents/Helpers/afterrayd"
  do
    pids=()
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(pgrep -f -x "$executable" 2>/dev/null || true)
    if ((${#pids[@]} > 0)); then
      kill "${pids[@]}" 2>/dev/null || true
    fi
  done

  # Give applicationWillTerminate time to unregister its global shortcut and
  # stop the child daemon before replacing the development app bundle.
  for _ in {1..30}; do
    if ! pgrep -f -x "$app_bundle/Contents/MacOS/AfterRay" >/dev/null 2>&1 \
      && ! pgrep -f -x "$app_bundle/Contents/Helpers/afterrayd" >/dev/null 2>&1
    then
      return
    fi
    sleep 0.1
  done
}

mkdir -p "$swift_cache/clang" "$swift_cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$swift_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="$swift_cache/swiftpm"

printf '%s\n' '==> Building native ScreenCaptureKit shim'
swift build \
  --package-path "$capture_package" \
  --configuration release \
  --product AfterRayCaptureShim

printf '%s\n' '==> Building Rust daemon and CLI'
cargo build --manifest-path "$repo_root/Cargo.toml" --workspace --release

printf '%s\n' '==> Building Swift recall app'
swift build \
  --package-path "$repo_root" \
  --configuration debug \
  --product afterray-app
swift build \
  --package-path "$repo_root" \
  --configuration release \
  --product afterray-native-model-worker
swift build \
  --package-path "$repo_root" \
  --configuration release \
  --product afterray-mlx-vlm-worker

printf '%s\n' '==> Assembling AfterRay.app'
stop_development_processes
case "$app_bundle" in
  "$repo_root"/.afterray-dev/AfterRay.app) rm -rf -- "$app_bundle" ;;
  *) printf 'Refusing to replace unexpected app bundle: %s\n' "$app_bundle" >&2; exit 1 ;;
esac
mkdir -p \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Helpers" \
  "$app_bundle/Contents/Resources"
cp "$repo_root/apps/AfterRay/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$repo_root/apps/AfterRay/Resources/AppIcon.icns" \
  "$app_bundle/Contents/Resources/AppIcon.icns"
cp "$repo_root/LICENSES/Qwen3.5-4B-MLX-4bit-NOTICE.txt" \
  "$app_bundle/Contents/Resources/Qwen3.5-4B-MLX-4bit-NOTICE.txt"
cp "$app_bin" "$app_bundle/Contents/MacOS/AfterRay"
cp "$daemon_bin" "$app_bundle/Contents/Helpers/afterrayd"
cp "$cli_bin" "$app_bundle/Contents/Helpers/afterray"
cp "$capture_shim" "$app_bundle/Contents/Helpers/AfterRayCaptureShim"
cp "$native_model_worker" "$app_bundle/Contents/Helpers/afterray-native-model-worker"
cp "$mlx_model_worker" "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker"
cp "$model_worker" "$app_bundle/Contents/Helpers/afterray-model-worker"
chmod +x "$app_bundle/Contents/MacOS/AfterRay" "$app_bundle/Contents/Helpers/"*
codesign_identity="$(resolve_codesign_identity)"
if [[ "$codesign_identity" == '-' ]]; then
  printf '%s\n' \
    'WARNING: No Apple Development or Developer ID signing identity was found.' \
    'Screen Recording permission may be lost after every ad-hoc rebuild.' >&2
fi
printf '==> Signing with: %s\n' "$codesign_identity"
xcrun swift-stdlib-tool \
  --copy \
  --scan-executable "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker" \
  --platform macosx \
  --destination "$app_bundle/Contents/Helpers" \
  --sign "$codesign_identity"
rm -f "$app_bundle/Contents/Helpers/libswiftCompatibilitySpan.dylib.original"
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/afterrayd" >/dev/null
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/afterray" >/dev/null
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/AfterRayCaptureShim" >/dev/null
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/afterray-native-model-worker" >/dev/null
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker" >/dev/null
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/libswiftCompatibilitySpan.dylib" >/dev/null
codesign --force --sign "$codesign_identity" "$app_bundle/Contents/Helpers/afterray-model-worker" >/dev/null
if [[ "$codesign_identity" == '-' ]]; then
  codesign \
    --force \
    --sign - \
    --identifier dev.afterray.app \
    --requirements '=designated => identifier "dev.afterray.app"' \
    "$app_bundle" >/dev/null
else
  # Certificate-backed signing gives TCC a stable identity across rebuilds.
  # Let codesign synthesize the designated requirement from the certificate,
  # team identifier, and bundle identifier.
  codesign \
    --force \
    --sign "$codesign_identity" \
    "$app_bundle" >/dev/null
fi
codesign --verify --deep --strict "$app_bundle"

if [[ "$mode" == 'build' ]]; then
  printf '%s\n' 'AfterRay V0 build completed.'
  exit 0
fi

run_dir="$(mktemp -d /tmp/afterray-v0.XXXXXX)"
daemon_pid=''

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  case "$run_dir" in
    /tmp/afterray-v0.*)
      rm -rf -- "$run_dir"
      ;;
    *)
      printf 'Refusing to clean unexpected run directory: %s\n' "$run_dir" >&2
      ;;
  esac
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

export AFTERRAY_SOCKET="$run_dir/afterray.sock"
if [[ "$ephemeral" == 'true' ]]; then
  export AFTERRAY_DATA_DIR="$run_dir/data"
else
  export AFTERRAY_DATA_DIR="${AFTERRAY_DATA_DIR:-$repo_root/.afterray/v0-data}"
fi
export AFTERRAY_CAPTURE_SHIM="$capture_shim"
export AFTERRAY_NATIVE_MODEL_WORKER="$native_model_worker"
export AFTERRAY_GOP_ARCHIVE="${AFTERRAY_GOP_ARCHIVE:-1}"
export AFTERRAY_GOP_REQUIRE_AC="${AFTERRAY_GOP_REQUIRE_AC:-0}"
export AFTERRAY_GOP_KEYINT="${AFTERRAY_GOP_KEYINT:-30}"
mkdir -p "$AFTERRAY_DATA_DIR"
default_asr_model="$repo_root/.afterray/models/Qwen3-ASR-1.7B"
if [[ -z "${AFTERRAY_ASR_MODEL:-}" && -d "$default_asr_model" ]]; then
  export AFTERRAY_ASR_MODEL="$default_asr_model"
fi
default_embedding_model="$repo_root/.afterray/models/nomic-embed-text-v1.5.Q4_K_M.gguf"
if [[ -z "${AFTERRAY_EMBEDDING_MODEL:-}" && -f "$default_embedding_model" ]]; then
  export AFTERRAY_EMBEDDING_MODEL="$default_embedding_model"
fi
daemon_log="$run_dir/afterrayd.log"
app_log="$run_dir/afterray-app.log"

if [[ "$mode" == 'app' ]]; then
  if [[ "$ephemeral" != 'true' ]]; then
    # The app derives stable development socket/data paths from its bundle
    # location. Do not inject run-directory paths that disappear when macOS
    # performs Quit & Reopen after a privacy permission change.
    unset AFTERRAY_SOCKET AFTERRAY_DATA_DIR
  fi
  export AFTERRAY_DAEMON="$app_bundle/Contents/Helpers/afterrayd"
  export AFTERRAY_CAPTURE_SHIM="$app_bundle/Contents/Helpers/AfterRayCaptureShim"
  export AFTERRAY_NATIVE_MODEL_WORKER="$app_bundle/Contents/Helpers/afterray-native-model-worker"
  export AFTERRAY_MLX_WORKER="$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker"
  export AFTERRAY_MODEL_WORKER="$app_bundle/Contents/Helpers/afterray-model-worker"
  printf '%s\n' \
    '==> Opening AfterRay.app through LaunchServices' \
    'The app will request Screen Recording, Microphone, and Accessibility access.' \
    'Recording starts automatically once all three permissions are enabled.'

  # LaunchServices now reuses the bundle if a second runner is started. The
  # preflight above removes stale development instances before this build, so
  # only one process can own the global shortcut and permission flow.
  open_args=(-W -F --stderr "$app_log")
  launch_environment=(
    AFTERRAY_SOCKET
    AFTERRAY_DATA_DIR
    AFTERRAY_DAEMON
    AFTERRAY_CAPTURE_SHIM
    AFTERRAY_NATIVE_MODEL_WORKER
    AFTERRAY_MLX_WORKER
    AFTERRAY_MODEL_WORKER
    AFTERRAY_ASR_MODEL
    AFTERRAY_EMBEDDING_MODEL
    AFTERRAY_GOP_ARCHIVE
    AFTERRAY_GOP_KEYINT
    AFTERRAY_GOP_REQUIRE_AC
    PATH
  )
  for variable_name in "${launch_environment[@]}"; do
    if [[ -n "${!variable_name:-}" ]]; then
      open_args+=(--env "$variable_name=${!variable_name}")
    fi
  done
  open "${open_args[@]}" "$app_bundle"
  exit $?
fi

printf '==> Starting afterrayd\n    socket: %s\n    data:   %s\n' \
  "$AFTERRAY_SOCKET" "$AFTERRAY_DATA_DIR"
"$daemon_bin" >"$daemon_log" 2>&1 &
daemon_pid=$!

daemon_ready='false'
for _ in {1..100}; do
  if "$cli_bin" --json status >/dev/null 2>&1; then
    daemon_ready='true'
    break
  fi
  if ! kill -0 "$daemon_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [[ "$daemon_ready" != 'true' ]]; then
  printf '%s\n' 'afterrayd failed to become ready. Log follows:' >&2
  sed -n '1,240p' "$daemon_log" >&2
  exit 1
fi

printf '\n%s\n' 'AfterRay V0 daemon is ready.'
printf '%s\n' \
  'Daemon-only mode does not start recording automatically.' \
  'The app is responsible for requesting permissions and starting capture.' \
  'Grant the requested permissions, then retry the command if macOS asks you to.' \
  '' \
  'From another terminal, use:'
printf '  AFTERRAY_SOCKET=%q %q status\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '  AFTERRAY_SOCKET=%q %q record start\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '  AFTERRAY_SOCKET=%q %q record stop\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '  AFTERRAY_SOCKET=%q %q sessions list\n' "$AFTERRAY_SOCKET" "$cli_bin"
printf '\nDaemon log: %s\n' "$daemon_log"

printf '%s\n' 'Press Control-C to stop afterrayd and clean the temporary run directory.'
wait "$daemon_pid"
