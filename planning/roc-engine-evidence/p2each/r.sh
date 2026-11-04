#!/bin/bash
# Run the pinned roc in p2each/<dir>: r.sh DIR ARGS...
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
cd "$D/$1" || exit 1
shift
timeout ${TMO:-1200} /home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc "$@" 2>&1 | grep -v '^$' | head -${HEADN:-80}
