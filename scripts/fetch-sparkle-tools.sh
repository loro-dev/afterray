#!/usr/bin/env bash

# Downloads Sparkle's release tools (sign_update, generate_keys,
# generate_appcast) into .afterray-dev/. They are not part of the Swift package
# — that ships only the framework — so the release scripts need them fetched
# once per machine.

set -Eeuo pipefail

version='2.9.5'
# Pinned: these tools sign what every installed copy will accept as a genuine
# update, so the bytes must not change silently underneath a release.
tarball_sha256='015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc'

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
destination="$repo_root/.afterray-dev/sparkle-tools"

if [[ -x "$destination/bin/sign_update" && "${1:-}" != '--force' ]]; then
  printf 'Sparkle %s tools already present: %s\n' "$version" "$destination/bin"
  exit 0
fi

for tool in curl shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

temp_root="$(mktemp -d /tmp/afterray-sparkle-tools.XXXXXX)"
cleanup() {
  local status=$?
  case "$temp_root" in
    /tmp/afterray-sparkle-tools.*) rm -rf -- "$temp_root" ;;
  esac
  exit "$status"
}
trap cleanup EXIT

url="https://github.com/sparkle-project/Sparkle/releases/download/${version}/Sparkle-${version}.tar.xz"
printf 'Downloading %s\n' "$url"
curl -sSL -o "$temp_root/sparkle.tar.xz" "$url"

actual="$(shasum -a 256 "$temp_root/sparkle.tar.xz" | awk '{print $1}')"
[[ "$actual" == "$tarball_sha256" ]] \
  || die "checksum mismatch for Sparkle $version: expected $tarball_sha256, got $actual"

mkdir -p "$temp_root/unpacked"
tar -xJf "$temp_root/sparkle.tar.xz" -C "$temp_root/unpacked"
[[ -x "$temp_root/unpacked/bin/sign_update" ]] || die 'sign_update missing from the Sparkle tarball'

rm -rf -- "$destination"
mkdir -p "$(dirname "$destination")"
mv "$temp_root/unpacked" "$destination"

printf 'Installed Sparkle %s tools: %s\n' "$version" "$destination/bin"
