# Shared paths for the spike scripts. Sources come from this worktree's
# spike/roc-engine; build trees go to the scratch directory $P (never the repo).
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRATCH=${SCRATCH:-/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad}
P=${P5:-$SCRATCH/p5}
LOCK=$SCRATCH/spike-results/timing.lock
FUZZPF=$SCRATCH/spike-results/roc-engine/p0a/fuzzpf/main.roc
ZIG=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0/zig
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
PUPPETEER_NODE_PATH=$SCRATCH/spike-results/jfb/jfb/webdriver-ts/node_modules
mkdir -p $P $P/results
