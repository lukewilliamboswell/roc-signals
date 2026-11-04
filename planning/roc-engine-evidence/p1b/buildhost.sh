#!/bin/sh
export PATH=/nix/store/1lrz2a4z36ywhcf3jyxaxv8lw7mzmslh-zig-0.16.0/bin:$PATH
cd /home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a0bf066f512ab7d5d || exit 1
zig build build-test-hosts -Doptimize=ReleaseFast > /tmp/claude-1000/re/p1b/hostbuild.log 2>&1
echo "exit $?" >> /tmp/claude-1000/re/p1b/hostbuild.log
