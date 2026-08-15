#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
app_bundle="$repo_root/.afterray-dev/AfterRay.app"

mode='normal'
if (($# > 0)); then
  case "$1" in
    --onboarding) mode='onboarding' ;;
    *) printf 'Usage: %s [--onboarding]\n' "$0" >&2; exit 64 ;;
  esac
fi
if (($# > 1)); then
  printf 'Usage: %s [--onboarding]\n' "$0" >&2
  exit 64
fi

if [[ ! -d "$app_bundle" ]]; then
  printf '%s\n' 'AfterRay.app has not been built. Run `make dev` or `make v0-build` first.' >&2
  exit 66
fi

if [[ "$mode" == 'onboarding' ]]; then
  open -n "$app_bundle" --args --onboarding
else
  open "$app_bundle"
fi
