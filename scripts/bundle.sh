#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
roc_bin="${ROC_BIN:-${ROC:-roc}}"
out_dir="${BUNDLE_OUT_DIR:-$root_dir}"

cd "$root_dir/platform"

roc_files=(*.roc)
host_files=()
for file in targets/*/*.a targets/*/*.lib targets/*/*.wasm targets/*/*.o; do
  if [[ -f "$file" ]]; then
    host_files+=("$file")
  fi
done

extra_files=()
if [[ -f "$root_dir/THIRD_PARTY_LICENSES.md" ]]; then
  if [[ ! -f THIRD_PARTY_LICENSES.md ]]; then
    cp "$root_dir/THIRD_PARTY_LICENSES.md" .
    trap 'rm -f THIRD_PARTY_LICENSES.md' EXIT
  fi
  extra_files+=(THIRD_PARTY_LICENSES.md)
fi

if [[ ${#host_files[@]} -eq 0 ]]; then
  echo "No platform host artifacts found; run 'zig build build-test-hosts' first." >&2
  exit 1
fi

mkdir -p "$out_dir"
echo "Bundling ${#roc_files[@]} .roc files, ${#host_files[@]} host files, and ${#extra_files[@]} extra files..."
"$roc_bin" bundle "${roc_files[@]}" "${host_files[@]}" "${extra_files[@]}" --output-dir "$out_dir" "$@"
