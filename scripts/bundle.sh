#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
roc_bin="${ROC_BIN:-${ROC:-roc}}"
out_dir="${BUNDLE_OUT_DIR:-$root_dir}"

cd "$root_dir/platform"

roc_files=(*.roc)
host_files=()
for file in targets/*/*.a targets/*/*.lib targets/*/*.wasm; do
  if [[ -f "$file" ]]; then
    host_files+=("$file")
  fi
done

if [[ ${#host_files[@]} -eq 0 ]]; then
  echo "No platform host artifacts found; run 'zig build build-test-hosts' first." >&2
  exit 1
fi

mkdir -p "$out_dir"
echo "Bundling ${#roc_files[@]} .roc files and ${#host_files[@]} host files..."
"$roc_bin" bundle "${roc_files[@]}" "${host_files[@]}" --output-dir "$out_dir" "$@"
