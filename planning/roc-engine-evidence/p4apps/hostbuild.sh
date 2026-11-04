#!/bin/sh
# Build the current engine's ReleaseFast native/wasm hosts in this worktree.
export PATH=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0:$PATH
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
cd /home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a33232d168c0dba47 || exit 1
zig build build-test-hosts -Doptimize=ReleaseFast > $P/hostbuild.log 2>&1
echo "exit $?" >> $P/hostbuild.log
