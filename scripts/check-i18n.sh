#!/usr/bin/env bash
# Static completeness checks for AfterRay UI chrome i18n.
# See swift/AfterRayRecall/Sources/L10n/AGENTS.md.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$script_dir/check-i18n.py" "$@"
