#!/bin/bash
# Re-run the official js-framework-benchmark comparison end to end.
set -e
S=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad
J=$S/spike-results/jfb/jfb; O=$S/spike-results/jfb-official; K=$J/frameworks/keyed
ZIGDIR=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0
# 1. official harness (root needs --legacy-peer-deps: eslint 10 vs eslint-plugin-react peer range)
cd $J && npm ci --no-audit --no-fund --legacy-peer-deps && npm run install-webdriver-ts && npm run install-server
mkdir -p $J/frameworks/non-keyed   # server /ls scans it; the clone lacks it
(cd $K/solid && npm ci --no-audit --no-fund && npm run build-prod)
# 2. adapters
bash $O/make_adapters.sh
for n in roc-engine-p1 roc-d-each roc-d-p3copy roc-d-p3m; do (cd $K/$n && npm install --package-lock-only && npm run build-prod); done
# current engine: main checkout's pinned compiler (2026-09-12), Zig 0.16 on PATH, PYTHONPATH for runpy imports
mkdir -p $K/roc-signals && cp -r /home/lbw/Documents/Github/roc-signals/benchmarks/js-framework-benchmark/roc-signals-keyed/. $K/roc-signals/
(cd $K/roc-signals && npm ci && PATH=$ZIGDIR:$PATH PYTHONPATH=/home/lbw/Documents/Github/roc-signals/scripts \
  ROC_SIGNALS_ROOT=/home/lbw/Documents/Github/roc-signals ROC_BIN=/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc npm run build-prod)
# 3. server, isKeyed, bench (bench holds timing.lock per framework), summary
(cd $J && nohup npm start > $O/logs/server.log 2>&1 &) ; sleep 5
(cd $J/webdriver-ts && npm run isKeyed -- --headless true --chromeBinary /usr/bin/google-chrome --framework keyed/solid keyed/roc-signals keyed/roc-engine-p1 keyed/roc-d-each keyed/roc-d-p3copy keyed/roc-d-p3m)
bash $O/run_all.sh
python3 -I $O/summarize.py $O/results > $O/summary.md
