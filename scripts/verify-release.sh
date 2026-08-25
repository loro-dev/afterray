#!/usr/bin/env bash

# Verifies a completed production manifest from the recipient's perspective.

set -Eeuo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: scripts/verify-release.sh dist/AfterRay-<version>-arm64.json\n' >&2
  exit 64
}

[[ $# -eq 1 ]] || usage

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
manifest_path="$1"
[[ "$manifest_path" = /* ]] || manifest_path="$repo_root/$manifest_path"
[[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"

for tool in ditto hdiutil python3 shasum spctl xattr xcrun; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

read_field() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    value = json.load(handle).get(sys.argv[2])
if value is None:
    raise SystemExit("missing field: " + sys.argv[2])
print(value)
' "$manifest_path" "$1"
}

[[ "$(read_field notarized)" == 'True' ]] || die 'manifest is not notarized'
[[ "$(read_field source_dirty)" == 'False' ]] || die 'manifest was built from a dirty worktree'
signature="$(read_field update_signature)"
[[ -n "$signature" ]] || die 'manifest has no Sparkle update signature'

release_dir="$(dirname "$manifest_path")"
dmg_path="$release_dir/$(read_field artifact)"
zip_path="$release_dir/$(read_field update_archive)"
dmg_sha="$(read_field sha256)"
zip_sha="$(read_field update_archive_sha256)"
[[ -f "$dmg_path" && -f "$zip_path" ]] || die 'manifest artifacts are missing'

checksum() {
  shasum -a 256 "$1" | awk '{print $1}'
}
[[ "$(checksum "$dmg_path")" == "$dmg_sha" ]] || die 'DMG checksum does not match manifest'
[[ "$(checksum "$zip_path")" == "$zip_sha" ]] || die 'update archive checksum does not match manifest'

temp_root="$(mktemp -d /tmp/afterray-release-verify.XXXXXX)"
mount_point="$temp_root/mount"
dragged_app="$temp_root/AfterRay.app"
mkdir "$mount_point"
cleanup() {
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  rm -rf -- "$temp_root"
}
trap cleanup EXIT

hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg_path" >/dev/null
ditto "$mount_point/AfterRay.app" "$dragged_app"
hdiutil detach "$mount_point" >/dev/null
[[ -f "$dragged_app/Contents/Helpers/mlx.metallib" ]] \
  || die 'dragged app is missing the MLX Metal library'
[[ -x "$dragged_app/Contents/Helpers/asr/afterray-mlx-asr-worker" ]] \
  || die 'dragged app is missing the MLX ASR worker'
[[ -f "$dragged_app/Contents/Helpers/asr/mlx.metallib" ]] \
  || die 'dragged app is missing the MLX ASR Metal library'
xcrun stapler validate "$dragged_app"
xattr -w com.apple.quarantine '0081;00000000;Safari;' "$dragged_app"
spctl --assess --type execute --verbose=2 "$dragged_app"

printf 'Verified release manifest: %s\n' "$manifest_path"
