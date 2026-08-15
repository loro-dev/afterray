#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/build-release.sh [--local | --skip-notarization] [--allow-dirty]' \
    '' \
    'Builds the complete Apple Silicon AfterRay distribution:' \
    '  - Swift app, capture shim, and native model worker in release mode' \
    '  - Rust daemon, CLI, and model worker in release mode' \
    '  - nested-code signing, DMG creation, notarization, and stapling' \
    '' \
    'Modes:' \
    '  no mode option        Developer ID sign, notarize, staple, and verify' \
    '  --skip-notarization   Developer ID sign and package an explicitly unnotarized DMG' \
    '  --local               ad-hoc sign and package an explicitly local-only DMG' \
    '' \
    'Options:' \
    '  --allow-dirty         permit building from an uncommitted worktree' \
    '  -h, --help            show this help' \
    '' \
    'Environment:' \
    '  AFTERRAY_CODESIGN_IDENTITY  Developer ID Application name or SHA-1; auto-detected if unset' \
    '  AFTERRAY_NOTARY_PROFILE     notarytool Keychain profile; required for the default mode'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '==> %s\n' "$*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

mode='release'
allow_dirty='false'
while (($# > 0)); do
  case "$1" in
    --local)
      [[ "$mode" == 'release' ]] || die 'only one release mode may be selected'
      mode='local'
      ;;
    --skip-notarization)
      [[ "$mode" == 'release' ]] || die 'only one release mode may be selected'
      mode='unnotarized'
      ;;
    --allow-dirty)
      allow_dirty='true'
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
release_dir="$repo_root/dist"
source_plist="$repo_root/apps/AfterRay/Resources/Info.plist"
plist_buddy='/usr/libexec/PlistBuddy'
temp_root=''

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$temp_root" ]]; then
    case "$temp_root" in
      /tmp/afterray-release.*) rm -rf -- "$temp_root" ;;
      *) printf 'warning: refusing to clean unexpected temporary path: %s\n' "$temp_root" >&2 ;;
    esac
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

for tool in awk cargo codesign ditto git hdiutil lipo ln mkdir otool security shasum spctl swift tail xcrun; do
  require_tool "$tool"
done
[[ -x "$plist_buddy" ]] || die "required tool not found: $plist_buddy"
[[ "$(uname -m)" == 'arm64' ]] || die 'AfterRay releases currently support Apple Silicon only; build on an arm64 Mac'

dirty_state="$(git -C "$repo_root" status --porcelain --untracked-files=normal)"
if [[ -n "$dirty_state" && "$allow_dirty" != 'true' ]]; then
  die 'worktree is dirty; commit the release source or pass --allow-dirty for a non-production check'
fi
if [[ -n "$dirty_state" ]]; then
  printf '%s\n' 'WARNING: building from a dirty worktree.' >&2
  source_dirty='true'
else
  source_dirty='false'
fi

version="$($plist_buddy -c 'Print :CFBundleShortVersionString' "$source_plist")"
build_number="$($plist_buddy -c 'Print :CFBundleVersion' "$source_plist")"
bundle_identifier="$($plist_buddy -c 'Print :CFBundleIdentifier' "$source_plist")"
minimum_macos="$($plist_buddy -c 'Print :LSMinimumSystemVersion' "$source_plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "invalid CFBundleShortVersionString: $version"
[[ "$build_number" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid CFBundleVersion: $build_number"
[[ "$minimum_macos" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "invalid LSMinimumSystemVersion: $minimum_macos"
[[ "$bundle_identifier" == 'dev.afterray.app' ]] || die "unexpected bundle identifier: $bundle_identifier"

workspace_version="$(awk '
  /^\[workspace\.package\]$/ { in_workspace_package = 1; next }
  /^\[/ { in_workspace_package = 0 }
  in_workspace_package && /^version[[:space:]]*=/ {
    value = $0
    sub(/^[^=]*=[[:space:]]*"/, "", value)
    sub(/"[[:space:]]*$/, "", value)
    print value
    exit
  }
' "$repo_root/Cargo.toml")"
[[ -n "$workspace_version" ]] || die 'could not read workspace.package.version from Cargo.toml'
[[ "$workspace_version" == "$version" ]] || die "Info.plist version $version does not match Cargo workspace version $workspace_version"

resolve_developer_id_identity() {
  if [[ -n "${AFTERRAY_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$AFTERRAY_CODESIGN_IDENTITY"
    return
  fi

  local identities
  local line
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ "$line" == *'"Developer ID Application:'* ]] || continue
    line="${line#*\"}"
    printf '%s\n' "${line%%\"*}"
    return
  done <<<"$identities"
}

if [[ "$mode" == 'local' ]]; then
  codesign_identity='-'
  notary_profile=''
  artifact_suffix='-local'
  notarized='false'
else
  codesign_identity="$(resolve_developer_id_identity)"
  [[ -n "$codesign_identity" ]] || die 'no Developer ID Application identity found; install one or set AFTERRAY_CODESIGN_IDENTITY'
  notary_profile="${AFTERRAY_NOTARY_PROFILE:-}"
  if [[ "$mode" == 'release' ]]; then
    [[ -n "$notary_profile" ]] || die 'AFTERRAY_NOTARY_PROFILE is required for a notarized release'
    artifact_suffix=''
  else
    artifact_suffix='-unnotarized'
  fi
  notarized='false'
fi

artifact_stem="AfterRay-${version}${artifact_suffix}-arm64"
output_root="$release_dir/$artifact_stem"
app_bundle="$output_root/AfterRay.app"
dmg_path="$release_dir/$artifact_stem.dmg"
checksum_path="$dmg_path.sha256"
manifest_path="$release_dir/$artifact_stem.json"

case "$output_root" in
  "$repo_root"/dist/AfterRay-*-arm64) ;;
  *) die "refusing to replace unexpected release directory: $output_root" ;;
esac
mkdir -p "$release_dir"
rm -rf -- "$output_root"
rm -f -- "$dmg_path" "$checksum_path" "$manifest_path"
temp_root="$(mktemp -d /tmp/afterray-release.XXXXXX)"

swift_cache="$repo_root/.afterray-dev/release-swift-cache"
mkdir -p "$swift_cache/clang" "$swift_cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$swift_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache/clang"
export SWIFTPM_CUSTOM_CACHE_PATH="$swift_cache/swiftpm"

step 'Building ScreenCaptureKit helper (release)'
swift build \
  --package-path "$repo_root/apps/AfterRayCaptureShim" \
  --configuration release \
  --product AfterRayCaptureShim

step 'Building Rust daemon, CLI, and model worker (release, locked)'
cargo build \
  --manifest-path "$repo_root/Cargo.toml" \
  --target-dir "$repo_root/target" \
  --release \
  --locked \
  -p afterrayd \
  -p afterray-cli \
  -p afterray-infer

step 'Building Swift app and native model workers (release)'
swift build \
  --package-path "$repo_root" \
  --configuration release \
  --product afterray-app
swift build \
  --package-path "$repo_root" \
  --configuration release \
  --product afterray-native-model-worker
swift build \
  --package-path "$repo_root" \
  --configuration release \
  --product afterray-mlx-vlm-worker

capture_bin="$repo_root/apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim"
daemon_bin="$repo_root/target/release/afterrayd"
cli_bin="$repo_root/target/release/afterray"
model_worker_bin="$repo_root/target/release/afterray-model-worker"
app_bin="$repo_root/.build/release/afterray-app"
native_model_worker_bin="$repo_root/.build/release/afterray-native-model-worker"
mlx_worker_bin="$repo_root/.build/release/afterray-mlx-vlm-worker"
source_binaries=(
  "$app_bin"
  "$daemon_bin"
  "$cli_bin"
  "$model_worker_bin"
  "$capture_bin"
  "$native_model_worker_bin"
  "$mlx_worker_bin"
)
for binary in "${source_binaries[@]}"; do
  [[ -x "$binary" ]] || die "expected release executable is missing: $binary"
done

step 'Assembling complete AfterRay.app'
mkdir -p \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Helpers" \
  "$app_bundle/Contents/Resources"
install -m 0644 "$source_plist" "$app_bundle/Contents/Info.plist"
install -m 0644 "$repo_root/apps/AfterRay/Resources/AppIcon.icns" \
  "$app_bundle/Contents/Resources/AppIcon.icns"
install -m 0644 "$repo_root/LICENSES/Qwen3.5-4B-MLX-4bit-NOTICE.txt" \
  "$app_bundle/Contents/Resources/Qwen3.5-4B-MLX-4bit-NOTICE.txt"
install -m 0755 "$app_bin" "$app_bundle/Contents/MacOS/AfterRay"
install -m 0755 "$daemon_bin" "$app_bundle/Contents/Helpers/afterrayd"
install -m 0755 "$cli_bin" "$app_bundle/Contents/Helpers/afterray"
install -m 0755 "$model_worker_bin" "$app_bundle/Contents/Helpers/afterray-model-worker"
install -m 0755 "$capture_bin" "$app_bundle/Contents/Helpers/AfterRayCaptureShim"
install -m 0755 "$native_model_worker_bin" \
  "$app_bundle/Contents/Helpers/afterray-native-model-worker"
install -m 0755 "$mlx_worker_bin" \
  "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker"
xcrun swift-stdlib-tool \
  --copy \
  --scan-executable "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker" \
  --platform macosx \
  --destination "$app_bundle/Contents/Helpers" \
  --sign "$codesign_identity"
rm -f "$app_bundle/Contents/Helpers/libswiftCompatibilitySpan.dylib.original"
plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null

bundle_binaries=(
  "$app_bundle/Contents/MacOS/AfterRay"
  "$app_bundle/Contents/Helpers/afterrayd"
  "$app_bundle/Contents/Helpers/afterray"
  "$app_bundle/Contents/Helpers/afterray-model-worker"
  "$app_bundle/Contents/Helpers/AfterRayCaptureShim"
  "$app_bundle/Contents/Helpers/afterray-native-model-worker"
  "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker"
)
runtime_libraries=(
  "$app_bundle/Contents/Helpers/libswiftCompatibilitySpan.dylib"
)
for library in "${runtime_libraries[@]}"; do
  [[ -f "$library" ]] || die "expected Swift runtime library is missing: $library"
done
for binary in "${bundle_binaries[@]}"; do
  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == 'arm64' ]] || die "expected arm64-only executable, got '$architectures': $binary"
  # The first otool line is the inspected executable path, not a dependency.
  dependencies="$(otool -L "$binary" | tail -n +2)"
  while IFS= read -r dependency_line; do
    dependency="${dependency_line#"${dependency_line%%[![:space:]]*}"}"
    dependency="${dependency%% *}"
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /System/Library/* | /usr/lib/*) ;;
      @rpath/*)
        [[ -f "$(dirname "$binary")/${dependency##*/}" ]] \
          || die "missing bundled dynamic dependency '$dependency': $binary"
        ;;
      *) die "executable has a non-system dynamic dependency '$dependency': $binary" ;;
    esac
  done <<<"$dependencies"
done

sign_executable() {
  local executable="$1"
  if [[ "$mode" == 'local' ]]; then
    codesign --force --options runtime --sign - "$executable" >/dev/null
  else
    codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$codesign_identity" \
      "$executable" >/dev/null
  fi
}

step "Signing nested executables (${codesign_identity})"
for library in "${runtime_libraries[@]}"; do
  sign_executable "$library"
done
for binary in "${bundle_binaries[@]:1}"; do
  sign_executable "$binary"
done
sign_executable "$app_bundle"

step 'Verifying code signatures and Hardened Runtime'
for binary in "${bundle_binaries[@]}"; do
  codesign --verify --strict --verbose=2 "$binary"
  signature_details="$(codesign -d --verbose=4 "$binary" 2>&1)"
  [[ "$signature_details" == *'runtime'* ]] || die "Hardened Runtime flag is missing: $binary"
done
for library in "${runtime_libraries[@]}"; do
  codesign --verify --strict --verbose=2 "$library"
  signature_details="$(codesign -d --verbose=4 "$library" 2>&1)"
  [[ "$signature_details" == *'runtime'* ]] || die "Hardened Runtime flag is missing: $library"
done
codesign --verify --deep --strict --verbose=2 "$app_bundle"

step 'Creating compressed DMG'
dmg_root="$temp_root/dmg"
mkdir -p "$dmg_root"
ditto "$app_bundle" "$dmg_root/AfterRay.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -volname 'AfterRay' \
  -srcfolder "$dmg_root" \
  -format UDZO \
  -ov \
  "$dmg_path" >/dev/null

if [[ "$mode" != 'local' ]]; then
  step 'Signing DMG'
  codesign --force --timestamp --sign "$codesign_identity" "$dmg_path" >/dev/null
  codesign --verify --verbose=2 "$dmg_path"
fi
hdiutil verify "$dmg_path" >/dev/null

if [[ "$mode" == 'release' ]]; then
  step "Submitting DMG for notarization (profile: $notary_profile)"
  xcrun notarytool submit \
    "$dmg_path" \
    --keychain-profile "$notary_profile" \
    --wait \
    --timeout 30m
  step 'Stapling and validating notarization ticket'
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  hdiutil verify "$dmg_path" >/dev/null
  spctl --assess --type execute --verbose=2 "$app_bundle"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
  notarized='true'
fi

checksum="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "${dmg_path##*/}" >"$checksum_path"
(cd "$release_dir" && shasum -a 256 -c "${checksum_path##*/}") >/dev/null
source_commit="$(git -C "$repo_root" rev-parse HEAD)"
cat >"$manifest_path" <<EOF
{
  "name": "AfterRay",
  "version": "$version",
  "build": "$build_number",
  "bundle_identifier": "$bundle_identifier",
  "minimum_macos": "$minimum_macos",
  "architecture": "arm64",
  "source_commit": "$source_commit",
  "source_dirty": $source_dirty,
  "notarized": $notarized,
  "artifact": "${dmg_path##*/}",
  "sha256": "$checksum"
}
EOF

printf '\n%s\n' 'AfterRay release build completed.'
printf '  App:      %s\n' "$app_bundle"
printf '  DMG:      %s\n' "$dmg_path"
printf '  SHA-256:  %s\n' "$checksum"
printf '  Manifest: %s\n' "$manifest_path"
if [[ "$mode" != 'release' ]]; then
  printf '\nWARNING: This artifact is marked %s and must not be published as a production release.\n' "$mode" >&2
fi
