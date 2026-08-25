#!/usr/bin/env bash

set -Eeuo pipefail

# Release artifacts contain no secrets and must remain readable after being
# copied to another account or machine, regardless of the caller's umask.
umask 022

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
    '  AFTERRAY_CODESIGN_REFERENCE_APP  signed app whose designated requirement must match' \
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
automation_entitlements="$repo_root/apps/AfterRay/Resources/Automation.entitlements"
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
bundle_identifier="$($plist_buddy -c 'Print :CFBundleIdentifier' "$source_plist")"
minimum_macos="$($plist_buddy -c 'Print :LSMinimumSystemVersion' "$source_plist")"
# Sparkle decides "is there an update" from CFBundleVersion and nothing else,
# so a build number that never moves means a published release nobody
# receives, with no error anywhere. The commit count is monotonic along a
# linear main and needs no manual bookkeeping; the source plist keeps a
# placeholder for development builds, which never update themselves.
build_number="${AFTERRAY_BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "invalid CFBundleShortVersionString: $version"
[[ "$build_number" =~ ^[0-9]+$ ]] || die "invalid CFBundleVersion: $build_number"
[[ "$build_number" -gt 0 ]] || die "CFBundleVersion must be positive: $build_number"
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

read_designated_requirement() {
  local code="$1"
  local requirement_output
  requirement_output="$(codesign -d -r- "$code" 2>&1)" || return
  awk '
    /^designated => / {
      sub(/^designated => /, "")
      print
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' <<<"$requirement_output"
}

resolve_sign_update() {
  if [[ -n "${AFTERRAY_SPARKLE_SIGN_UPDATE:-}" ]]; then
    printf '%s\n' "$AFTERRAY_SPARKLE_SIGN_UPDATE"
    return
  fi
  local cached="$repo_root/.afterray-dev/sparkle-tools/bin/sign_update"
  # An `if`, not `[[ … ]] &&`: a missing tool is a normal outcome here — a
  # local build has nothing to sign — but as the function's last command that
  # test would return non-zero, and `set -e` would end the run at the
  # assignment below, before the message that explains it.
  if [[ -x "$cached" ]]; then
    printf '%s\n' "$cached"
  fi
}

sign_update_bin="$(resolve_sign_update)"

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
    # An unsigned update archive is one no installed copy will accept, so a
    # release that reaches this point without the tool has silently produced
    # an unpublishable artifact.
    [[ -n "$sign_update_bin" ]] \
      || die 'sign_update not found; run scripts/fetch-sparkle-tools.sh or set AFTERRAY_SPARKLE_SIGN_UPDATE'
    artifact_suffix=''
  else
    artifact_suffix='-unnotarized'
  fi
  notarized='false'
fi

codesign_reference_app="${AFTERRAY_CODESIGN_REFERENCE_APP:-}"
reference_designated_requirement=''
if [[ -n "$codesign_reference_app" ]]; then
  [[ "$mode" != 'local' ]] \
    || die 'a local ad-hoc package cannot match a Developer ID reference app'
  [[ -d "$codesign_reference_app" ]] \
    || die 'AFTERRAY_CODESIGN_REFERENCE_APP is not an application bundle'
  codesign --verify --strict "$codesign_reference_app" \
    || die 'AFTERRAY_CODESIGN_REFERENCE_APP has an invalid signature'
  reference_designated_requirement="$(read_designated_requirement "$codesign_reference_app")" \
    || die 'could not read designated requirement from AFTERRAY_CODESIGN_REFERENCE_APP'
fi

artifact_stem="AfterRay-${version}${artifact_suffix}-arm64"
output_root="$release_dir/$artifact_stem"
app_bundle="$output_root/AfterRay.app"
dmg_path="$release_dir/$artifact_stem.dmg"
checksum_path="$dmg_path.sha256"
manifest_path="$release_dir/$artifact_stem.json"
# Sparkle updates from a zip, not the DMG: it is smaller, and unpacking it
# does not need a mounted volume.
update_archive_path="$release_dir/$artifact_stem.zip"

case "$output_root" in
  "$repo_root"/dist/AfterRay-*-arm64) ;;
  *) die "refusing to replace unexpected release directory: $output_root" ;;
esac
mkdir -p "$release_dir"
rm -rf -- "$output_root"
rm -f -- "$dmg_path" "$checksum_path" "$manifest_path" "$update_archive_path"
temp_root="$(mktemp -d /tmp/afterray-release.XXXXXX)"

# See docs/decisions/active/process/2026-08-22-local-release-library-validation.md.
app_entitlements="$automation_entitlements"
if [[ "$mode" == 'local' ]]; then
  # Ad-hoc signatures have no shared Team ID. Keep Hardened Runtime parity,
  # but let this explicitly unpublishable host load its separately signed
  # Sparkle framework. Developer ID builds retain library validation.
  app_entitlements="$temp_root/Local.entitlements"
  install -m 0600 "$automation_entitlements" "$app_entitlements"
  "$plist_buddy" \
    -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
    "$app_entitlements"
fi

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
mlx_asr_package="$repo_root/apps/AfterRayMlxAsrWorker"
swift build \
  --package-path "$mlx_asr_package" \
  --configuration release \
  --product afterray-mlx-asr-worker

capture_bin="$repo_root/apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim"
daemon_bin="$repo_root/target/release/afterrayd"
cli_bin="$repo_root/target/release/afterray"
model_worker_bin="$repo_root/target/release/afterray-model-worker"
app_bin="$repo_root/.build/release/afterray-app"
native_model_worker_bin="$repo_root/.build/release/afterray-native-model-worker"
mlx_worker_bin="$repo_root/.build/release/afterray-mlx-vlm-worker"
mlx_metallib="$repo_root/.build/release/mlx.metallib"
mlx_asr_bin_dir="$(swift build --package-path "$mlx_asr_package" --configuration release --show-bin-path)"
mlx_asr_worker_bin="$mlx_asr_bin_dir/afterray-mlx-asr-worker"
mlx_asr_metallib="$mlx_asr_bin_dir/mlx.metallib"
install -m 0644 "$mlx_metallib" "$mlx_asr_metallib"
source_binaries=(
  "$app_bin"
  "$daemon_bin"
  "$cli_bin"
  "$model_worker_bin"
  "$capture_bin"
  "$native_model_worker_bin"
  "$mlx_worker_bin"
  "$mlx_asr_worker_bin"
)
for binary in "${source_binaries[@]}"; do
  [[ -x "$binary" ]] || die "expected release executable is missing: $binary"
done
[[ -f "$mlx_metallib" ]] \
  || die "expected MLX Metal library is missing: $mlx_metallib"

step 'Assembling complete AfterRay.app'
mkdir -p \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Helpers" \
  "$app_bundle/Contents/Helpers/asr" \
  "$app_bundle/Contents/Resources"
install -m 0644 "$source_plist" "$app_bundle/Contents/Info.plist"
# Stamped into the assembled bundle, never the source tree, and always before
# signing (which happens further down) so the signature covers the real value.
"$plist_buddy" -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
install -m 0644 "$repo_root/apps/AfterRay/Resources/AppIcon.icns" \
  "$app_bundle/Contents/Resources/AppIcon.icns"
for loc in en zh-Hans zh-Hant ja ko es de fr; do
  mkdir -p "$app_bundle/Contents/Resources/${loc}.lproj"
  install -m 0644 "$repo_root/apps/AfterRay/Resources/${loc}.lproj/InfoPlist.strings" \
    "$app_bundle/Contents/Resources/${loc}.lproj/InfoPlist.strings"
done
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
install -m 0644 "$mlx_metallib" \
  "$app_bundle/Contents/Helpers/mlx.metallib"
install -m 0755 "$mlx_asr_worker_bin" \
  "$app_bundle/Contents/Helpers/asr/afterray-mlx-asr-worker"
install -m 0644 "$mlx_asr_metallib" \
  "$app_bundle/Contents/Helpers/asr/mlx.metallib"
xcrun swift-stdlib-tool \
  --copy \
  --scan-executable "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker" \
  --platform macosx \
  --destination "$app_bundle/Contents/Helpers" \
  --sign "$codesign_identity"
xcrun swift-stdlib-tool \
  --copy \
  --scan-executable "$app_bundle/Contents/Helpers/asr/afterray-mlx-asr-worker" \
  --platform macosx \
  --destination "$app_bundle/Contents/Helpers" \
  --sign "$codesign_identity"
rm -f "$app_bundle/Contents/Helpers/libswiftCompatibilitySpan.dylib.original"

step 'Embedding Sparkle.framework'
sparkle_framework="$(
  find "$repo_root/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' -print -quit
)"
[[ -n "$sparkle_framework" ]] \
  || die 'Sparkle.framework not found under .build/artifacts; run `swift package resolve` first'
embedded_sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app_bundle/Contents/Frameworks"
ditto "$sparkle_framework" "$embedded_sparkle"
# Sparkle's XPC services exist for sandboxed hosts. AfterRay is not sandboxed,
# so shipping them would mean signing and notarizing code that never runs.
rm -rf -- "$embedded_sparkle/Versions/B/XPCServices" "$embedded_sparkle/XPCServices"
# Headers and module maps are build inputs, not runtime ones.
for build_only in Headers PrivateHeaders Modules; do
  rm -rf -- "$embedded_sparkle/Versions/B/$build_only" "$embedded_sparkle/$build_only"
done
[[ -x "$embedded_sparkle/Versions/B/Autoupdate" ]] \
  || die 'embedded Sparkle.framework is missing Autoupdate'
[[ -d "$embedded_sparkle/Versions/B/Updater.app" ]] \
  || die 'embedded Sparkle.framework is missing Updater.app'

plutil -lint "$app_bundle/Contents/Info.plist" >/dev/null

bundle_binaries=(
  "$app_bundle/Contents/MacOS/AfterRay"
  "$app_bundle/Contents/Helpers/afterrayd"
  "$app_bundle/Contents/Helpers/afterray"
  "$app_bundle/Contents/Helpers/afterray-model-worker"
  "$app_bundle/Contents/Helpers/AfterRayCaptureShim"
  "$app_bundle/Contents/Helpers/afterray-native-model-worker"
  "$app_bundle/Contents/Helpers/afterray-mlx-vlm-worker"
  "$app_bundle/Contents/Helpers/asr/afterray-mlx-asr-worker"
)
nested_runtime_code=(
  "$app_bundle/Contents/Helpers/libswiftCompatibilitySpan.dylib"
  "$app_bundle/Contents/Helpers/mlx.metallib"
  "$app_bundle/Contents/Helpers/asr/mlx.metallib"
)
for code in "${nested_runtime_code[@]}"; do
  [[ -f "$code" ]] || die "expected nested runtime code is missing: $code"
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
      # Sparkle resolves through the app's @executable_path/../Frameworks rpath
      # rather than sitting beside the executable that links it.
      @rpath/Sparkle.framework/*)
        [[ -x "$embedded_sparkle/Versions/B/Sparkle" ]] \
          || die "missing embedded Sparkle.framework for dependency '$dependency': $binary"
        ;;
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
  local entitlements="${2:-}"
  local signing_args=(--force --options runtime)
  if [[ -n "$entitlements" ]]; then
    signing_args+=(--entitlements "$entitlements")
  fi
  if [[ "$mode" == 'local' ]]; then
    signing_args+=(--sign -)
  else
    signing_args+=(--timestamp --sign "$codesign_identity")
  fi
  codesign "${signing_args[@]}" "$executable" >/dev/null
}

if [[ "$mode" == 'local' ]]; then
  step 'Signing nested executables (ad-hoc)'
else
  step 'Signing nested executables (Developer ID)'
fi
# Sparkle signs from the inside out and explicitly without --deep: Autoupdate
# and Updater.app are separate executables that Gatekeeper evaluates on their
# own when they replace the running app.
sign_executable "$embedded_sparkle/Versions/B/Autoupdate"
sign_executable "$embedded_sparkle/Versions/B/Updater.app"
sign_executable "$embedded_sparkle"
for code in "${nested_runtime_code[@]}"; do
  sign_executable "$code"
done
for binary in "${bundle_binaries[@]:1}"; do
  if [[ "$binary" == "$app_bundle/Contents/Helpers/AfterRayCaptureShim" ]]; then
    sign_executable "$binary" "$automation_entitlements"
  else
    sign_executable "$binary"
  fi
done
sign_executable "$app_bundle" "$app_entitlements"

step 'Verifying code signatures and Hardened Runtime'
for binary in "${bundle_binaries[@]}"; do
  codesign --verify --strict --verbose=2 "$binary"
  signature_details="$(codesign -d --verbose=4 "$binary" 2>&1)"
  [[ "$signature_details" == *'runtime'* ]] || die "Hardened Runtime flag is missing: $binary"
done
for code in "${nested_runtime_code[@]}"; do
  codesign --verify --strict --verbose=2 "$code"
  signature_details="$(codesign -d --verbose=4 "$code" 2>&1)"
  [[ "$signature_details" == *'runtime'* ]] || die "Hardened Runtime flag is missing: $code"
done
for sparkle_component in \
  "$embedded_sparkle/Versions/B/Autoupdate" \
  "$embedded_sparkle/Versions/B/Updater.app" \
  "$embedded_sparkle"; do
  codesign --verify --strict --verbose=2 "$sparkle_component"
  signature_details="$(codesign -d --verbose=4 "$sparkle_component" 2>&1)"
  [[ "$signature_details" == *'runtime'* ]] \
    || die "Hardened Runtime flag is missing: $sparkle_component"
done
codesign --verify --deep --strict --verbose=2 "$app_bundle"
if [[ -n "$reference_designated_requirement" ]]; then
  step 'Verifying stable designated requirement'
  built_designated_requirement="$(read_designated_requirement "$app_bundle")" \
    || die 'could not read designated requirement from the packaged app'
  [[ "$built_designated_requirement" == "$reference_designated_requirement" ]] \
    || die 'packaged app designated requirement differs from the reference app; refusing a TCC-resetting artifact'
fi
app_signature_entitlements="$(codesign -d --entitlements :- "$app_bundle" 2>/dev/null)"
if [[ "$mode" == 'local' ]]; then
  [[ "$app_signature_entitlements" == *'com.apple.security.cs.disable-library-validation'* ]] \
    || die 'local app is missing the entitlement required to load ad-hoc nested code'
else
  [[ "$app_signature_entitlements" != *'com.apple.security.cs.disable-library-validation'* ]] \
    || die 'publishable app unexpectedly disables library validation'
fi

# `codesign --verify` checks each signature in isolation. Only dyld enforces
# the host/framework Team-ID relationship that can otherwise crash before
# `main`. This probe exits before NSApplication or any user data is opened.
step 'Probing packaged app dynamic loading'
AFTERRAY_PACKAGING_DYLD_PROBE=1 "$app_bundle/Contents/MacOS/AfterRay"

# Notarize the application before it goes into the DMG, so the ticket
# travels with what the user actually keeps. Stapling only the DMG leaves
# the dragged-out copy relying on an online check with Apple, which is a
# first-launch failure for anyone installing offline.
if [[ "$mode" == 'release' ]]; then
  step "Submitting app for notarization (profile: $notary_profile)"
  app_archive="$temp_root/AfterRay.zip"
  ditto -c -k --keepParent "$app_bundle" "$app_archive"
  xcrun notarytool submit \
    "$app_archive" \
    --keychain-profile "$notary_profile" \
    --wait \
    --timeout 30m
  step 'Stapling ticket to the application'
  xcrun stapler staple "$app_bundle"
  xcrun stapler validate "$app_bundle"
fi

# Built after stapling, and deliberately not reusing the archive submitted for
# notarization above: that one was made from the unstapled bundle. An update
# archive without the ticket installs an app that fails Gatekeeper the first
# time it launches on a machine that happens to be offline.
step 'Packaging the Sparkle update archive'
ditto -c -k --keepParent "$app_bundle" "$update_archive_path"
update_archive_size="$(/usr/bin/stat -f%z "$update_archive_path")"
update_signature=''
if [[ -n "$sign_update_bin" ]]; then
  step 'Signing the update archive (EdDSA)'
  signature_line="$("$sign_update_bin" "$update_archive_path")"
  update_signature="${signature_line#*edSignature=\"}"
  update_signature="${update_signature%%\"*}"
  [[ -n "$update_signature" && "$update_signature" != "$signature_line" ]] \
    || die "could not parse sign_update output: $signature_line"
fi

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
update_checksum="$(shasum -a 256 "$update_archive_path" | awk '{print $1}')"
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
  "sha256": "$checksum",
  "update_archive": "${update_archive_path##*/}",
  "update_archive_size": $update_archive_size,
  "update_archive_sha256": "$update_checksum",
  "update_signature": "$update_signature"
}
EOF

printf '\n%s\n' 'AfterRay release build completed.'
printf '  App:      %s\n' "$app_bundle"
printf '  DMG:      %s\n' "$dmg_path"
printf '  Update:   %s\n' "$update_archive_path"
printf '  Build:    %s\n' "$build_number"
printf '  SHA-256:  %s\n' "$checksum"
printf '  Manifest: %s\n' "$manifest_path"
if [[ -z "$update_signature" ]]; then
  printf '\nWARNING: The update archive is unsigned; no installed copy will accept it.\n' >&2
fi
if [[ "$mode" != 'release' ]]; then
  printf '\nWARNING: This artifact is marked %s and must not be published as a production release.\n' "$mode" >&2
fi
