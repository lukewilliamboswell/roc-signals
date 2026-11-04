#!/bin/sh
# Current engine native keyed-table bench (docs/profiling.md quick iteration),
# same machine, nightly 2026-11-01, hosts already built ReleaseFast by test.py.
export PATH=/nix/store/1lrz2a4z36ywhcf3jyxaxv8lw7mzmslh-zig-0.16.0/bin:$PATH
cd /home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-af7566db359447e9b || exit 1
OUT=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p0a
EXE=$OUT/current-jfb
: /home/lbw/roc_nightly-linux_x86_64-2026-11-01-48d3369/roc build --target=x64musl --opt=speed --no-cache \
:  examples-web/_fixtures/js-framework-benchmark/main.roc > "$OUT/current-build.log" 2>&1
[ -x "$EXE" ] || exit 1
: > "$OUT/current-bench.csv"
for c in create_1k:0 create_10k:0 update_10k:5 select_1k:5 swap_1k:5 remove_1k:5 append_1k_to_10k:0 clear_10k:0; do
  name=${c%%:*}; warm=${c##*:}
  "$EXE" --host-bench-app --host-bench-name "$name" --host-bench-warmup "$warm" \
    --host-bench-iterations 1 --host-bench-samples 7 --host-entropy-seed 0 \
    examples-web/_fixtures/js-framework-benchmark/specs/$name.scm >> "$OUT/current-bench.csv" 2>> "$OUT/current-bench.err"
done
