#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  printf '%s\n' \
    'Usage: scripts/build-mlx-metallib.sh' \
    '' \
    'Compiles the Metal shaders vendored in the mlx-swift checkout into' \
    'mlx.metallib and places it next to every built afterray-mlx-vlm-worker' \
    'binary (.build/release and .build/debug).' \
    '' \
    'Why this exists: command-line `swift build` cannot compile Metal shaders' \
    '(only xcodebuild can, per the mlx-swift README), so the worker binary has' \
    'no metallib and its first MLX call dies with "Failed to load the default' \
    'metallib". mlx looks for mlx.metallib in the worker binary'"'"'s directory' \
    'first (load_colocated_library), so colocating the compiled library is' \
    'enough. scripts/run-v0.sh and scripts/build-release.sh call this after' \
    'building the worker and copy the result into the app bundle next to it.'
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    ;;
  *)
    printf 'Unknown option: %s\n\n' "$1" >&2
    usage >&2
    exit 64
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
metal_dir="$repo_root/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
work_dir="$repo_root/.build/mlx-metallib"
metallib="$work_dir/mlx.metallib"

if [[ ! -d "$metal_dir" ]]; then
  printf 'error: mlx-swift checkout not found at %s; run `swift package resolve` first.\n' \
    "$metal_dir" >&2
  exit 1
fi

# Xcode 26 moved the offline Metal compiler into a downloadable component;
# without it `metal` is a stub that only prints the remedy.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  printf '%s\n' \
    'error: the Metal toolchain is not installed.' \
    'Install it once with: xcodebuild -downloadComponent MetalToolchain' >&2
  exit 1
fi

needs_build='false'
if [[ ! -f "$metallib" ]]; then
  needs_build='true'
else
  while IFS= read -r source_file; do
    if [[ "$source_file" -nt "$metallib" ]]; then
      needs_build='true'
      break
    fi
  done < <(find "$metal_dir" -type f \( -name '*.metal' -o -name '*.h' \))
  if [[ -f "$repo_root/Package.resolved" && "$repo_root/Package.resolved" -nt "$metallib" ]]; then
    needs_build='true'
  fi
fi

if [[ "$needs_build" == 'true' ]]; then
  mkdir -p "$work_dir"
  rm -f "$work_dir"/*.air
  air_files=()
  while IFS= read -r source_file; do
    air_file="$work_dir/$(basename "${source_file%.metal}").air"
    # Flags mirror mlx's own CMake kernel build (backend/metal/kernels/
    # CMakeLists.txt), retargeted at the flattened mlx-swift shader copy.
    xcrun -sdk macosx metal \
      -x metal \
      -Wall -Wextra \
      -fno-fast-math \
      -Wno-c++17-extensions \
      -Wno-c++20-extensions \
      -mmacosx-version-min=14.0 \
      -I"$metal_dir" \
      -c "$source_file" \
      -o "$air_file"
    air_files+=("$air_file")
  done < <(find "$metal_dir" -type f -name '*.metal' | sort)
  xcrun -sdk macosx metallib "${air_files[@]}" -o "$metallib"
  printf '==> Built %s\n' "$metallib"
fi

installed='false'
for configuration in release debug; do
  worker="$repo_root/.build/$configuration/afterray-mlx-vlm-worker"
  if [[ -x "$worker" ]]; then
    cp "$metallib" "$repo_root/.build/$configuration/mlx.metallib"
    installed='true'
  fi
done
if [[ "$installed" != 'true' ]]; then
  printf '%s\n' \
    'warning: no afterray-mlx-vlm-worker binary found under .build/;' \
    'built mlx.metallib only. Build the worker, then rerun this script.' >&2
fi
