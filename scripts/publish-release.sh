#!/usr/bin/env bash

# Publishes a built release to R2: uploads the update archive and the DMG, then
# adds the release to the index that /appcast.xml is generated from.
#
# The index entry is written last. Until it exists the artifacts are inert, so
# a failure part way through leaves installed copies on the previous release
# rather than pointing them at something half-uploaded.

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/publish-release.sh [--dry-run] [--critical] [manifest.json]' \
    '' \
    'Publishes the artifacts described by a dist/ manifest to the release' \
    'bucket, then appends them to releases.json so the appcast serves them.' \
    '' \
    'Options:' \
    '  --dry-run    show what would be uploaded and exit' \
    '  --critical   mark the release so Sparkle offers it without waiting' \
    '  -h, --help   show this help' \
    '' \
    'With no manifest, the newest publishable one in dist/ is used.'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '==> %s\n' "$*"
}

bucket='afterray-releases'
artifact_prefix='artifacts/'
index_key='releases.json'

dry_run='false'
critical='false'
manifest_path=''
while (($# > 0)); do
  case "$1" in
    --dry-run) dry_run='true' ;;
    --critical) critical='true' ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 64
      ;;
    *)
      [[ -z "$manifest_path" ]] || die 'only one manifest may be given'
      manifest_path="$1"
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
release_dir="$repo_root/dist"
wrangler_config="$repo_root/site/wrangler.jsonc"

for tool in npx python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[[ -f "$wrangler_config" ]] || die "missing wrangler config: $wrangler_config"

if [[ -z "$manifest_path" ]]; then
  # Only unsuffixed stems are publishable; -local and -unnotarized are not.
  manifest_path="$(
    find "$release_dir" -maxdepth 1 -type f -name 'AfterRay-*-arm64.json' \
      ! -name '*-local-*' ! -name '*-unnotarized-*' -print 2>/dev/null |
      sort |
      tail -n 1
  )"
  [[ -n "$manifest_path" ]] || die 'no publishable manifest found in dist/; run make release first'
fi
[[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path"

read_field() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    document = json.load(handle)
value = document.get(sys.argv[2])
if value is None:
    sys.exit("missing field: " + sys.argv[2])
print(json.dumps(value) if isinstance(value, bool) else value)
' "$manifest_path" "$1"
}

version="$(read_field version)"
build="$(read_field build)"
minimum_macos="$(read_field minimum_macos)"
notarized="$(read_field notarized)"
source_dirty="$(read_field source_dirty)"
dmg_name="$(read_field artifact)"
dmg_sha="$(read_field sha256)"
archive_name="$(read_field update_archive)"
archive_size="$(read_field update_archive_size)"
archive_sha="$(read_field update_archive_sha256)"
signature="$(read_field update_signature)"

step "Validating $manifest_path"
[[ "$notarized" == 'true' ]] || die 'refusing to publish an artifact that was not notarized'
[[ "$source_dirty" == 'false' ]] || die 'refusing to publish an artifact built from a dirty worktree'
[[ -n "$signature" ]] || die 'manifest has no update_signature; installed copies would reject the archive'
[[ "$build" =~ ^[0-9]+$ ]] || die "invalid build number: $build"

archive_path="$release_dir/$archive_name"
dmg_path="$release_dir/$dmg_name"
[[ -f "$archive_path" ]] || die "missing update archive: $archive_path"
[[ -f "$dmg_path" ]] || die "missing DMG: $dmg_path"

verify_checksum() {
  local path="$1" expected="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] \
    || die "checksum mismatch for $path: manifest says $expected, file is $actual"
}
verify_checksum "$archive_path" "$archive_sha"
verify_checksum "$dmg_path" "$dmg_sha"

wrangler() {
  npx --yes wrangler "$@" --config "$wrangler_config"
}

step "Fetching the current release index from r2://$bucket/$index_key"
index_local="$(mktemp /tmp/afterray-releases.XXXXXX.json)"
cleanup() {
  local status=$?
  rm -f -- "$index_local" "$index_local.next"
  exit "$status"
}
trap cleanup EXIT

if wrangler r2 object get "$bucket/$index_key" --file "$index_local" --remote >/dev/null 2>&1; then
  printf '  found %s bytes\n' "$(/usr/bin/stat -f%z "$index_local")"
else
  printf '  none yet; starting a new index\n'
  printf '{"releases": []}\n' >"$index_local"
fi

step "Adding build $build (version $version) to the index"
python3 - \
  "$index_local" "$index_local.next" "$version" "$build" "$minimum_macos" \
  "$archive_name" "$archive_size" "$signature" "$critical" <<'PYTHON'
import json, sys, datetime

(source, destination, version, build_text, minimum_macos,
 archive_name, archive_size, signature, critical) = sys.argv[1:10]

with open(source) as handle:
    index = json.load(handle)

releases = index.get("releases", [])
build = int(build_text)

# Sparkle only ever moves forward. Republishing a build number that already
# exists would leave installed copies unable to tell the two apart, and a lower
# one would simply never be offered — silently, which is worse.
for existing in releases:
    if int(existing["build"]) == build:
        sys.exit(f"build {build} is already published; bump CFBundleVersion")
highest = max((int(item["build"]) for item in releases), default=0)
if build < highest:
    sys.exit(f"build {build} is older than the published {highest}; refusing to go backwards")

entry = {
    "version": version,
    "build": build_text,
    "minimumSystemVersion": minimum_macos,
    "archive": archive_name,
    "length": int(archive_size),
    "edSignature": signature,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
if critical == "true":
    entry["criticalUpdate"] = True

releases.append(entry)
index["releases"] = releases
with open(destination, "w") as handle:
    json.dump(index, handle, indent=2)
    handle.write("\n")
PYTHON

if [[ "$dry_run" == 'true' ]]; then
  printf '\nDry run. Would upload:\n'
  printf '  r2://%s/%s%s  (%s bytes)\n' "$bucket" "$artifact_prefix" "$archive_name" "$archive_size"
  printf '  r2://%s/%s%s\n' "$bucket" "$artifact_prefix" "$dmg_name"
  printf '  r2://%s/%s  with this content:\n\n' "$bucket" "$index_key"
  cat "$index_local.next"
  exit 0
fi

step "Uploading $archive_name"
wrangler r2 object put "$bucket/$artifact_prefix$archive_name" \
  --file "$archive_path" \
  --content-type 'application/zip' \
  --cache-control 'public, max-age=31536000, immutable' \
  --remote

step "Uploading $dmg_name"
wrangler r2 object put "$bucket/$artifact_prefix$dmg_name" \
  --file "$dmg_path" \
  --content-type 'application/x-apple-diskimage' \
  --cache-control 'public, max-age=31536000, immutable' \
  --remote

# Last, so the artifacts are already in place by the time anything points here.
step "Updating $index_key"
wrangler r2 object put "$bucket/$index_key" \
  --file "$index_local.next" \
  --content-type 'application/json' \
  --cache-control 'no-cache' \
  --remote

printf '\n%s\n' "Published AfterRay $version (build $build)."
printf '  Appcast:  https://afterray.com/appcast.xml\n'
printf '  Update:   https://afterray.com/download/%s\n' "$archive_name"
printf '  Download: https://afterray.com/download/%s\n' "$dmg_name"
