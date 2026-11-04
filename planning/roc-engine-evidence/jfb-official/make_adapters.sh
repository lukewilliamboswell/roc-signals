#!/bin/bash
# Create the Roc-engine jfb adapters under frameworks/keyed (no removals; overwrite in place).
set -e
J=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/jfb; K=$J/frameworks/keyed
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine
W=/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a0100dec5919ab717
ZIG=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0/zig
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
# Phase 1 static engine: the worktree adapter, copied
mkdir -p $K/roc-engine-p1
cp -r $W/benchmarks/js-framework-benchmark/roc-engine-keyed/{app,src,build.py,index.html} $K/roc-engine-p1/
ln -sfn $W/platform-roc $K/roc-engine-p1/platform-roc
sed -i 's#platform "[^"]*"#platform "../platform-roc/main.roc"#' $K/roc-engine-p1/app/main.roc
cat >$K/roc-engine-p1/package.json <<EOF
{
  "name": "js-framework-benchmark-roc-engine-p1",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "main": "dist/main.mjs",
  "js-framework-benchmark": {
    "frameworkVersion": "0.0.1",
    "frameworkHomeURL": "https://github.com/lukewilliamboswell/roc-signals",
    "language": "WebAssembly"
  },
  "scripts": {
    "dev": "npm run build-prod",
    "build-prod": "ROC_SIGNALS_ROOT=\${ROC_SIGNALS_ROOT:-$W} ZIG=\${ZIG:-$ZIG} ROC_BIN=\${ROC_BIN:-$ROC} python3 build.py"
  },
  "license": "UPL-1.0"
}
EOF
mk() { name=$1; pfdir=$2; engine=$3; desc=$4
 D=$K/$name; mkdir -p $D/app $D/src
 cp $P/p2each/keyed/app/main.roc $P/p2each/keyed/app/Jfb.roc $D/app/
 cp $P/p2each/keyed/src/main.mjs $D/src/
 sed "s/Roc Engine-keyed/$name-keyed/" $P/p2each/keyed/index.html > $D/index.html
 cat > $D/build.sh <<EOF
#!/bin/bash
# $desc
# Builds app/ against a private copy of the spike platform (build/), then copies
# app.wasm, runtime.mjs and main.mjs into dist/. Override PLATFORM, ENGINE, ROC, OPT.
set -euo pipefail
HERE=\$(cd "\$(dirname "\$0")" && pwd)
PLATFORM=\${PLATFORM:-$pfdir}
ENGINE=\${ENGINE:-$engine}
ROC=\${ROC:-$ROC}
OPT=\${OPT:-speed}
B=\$HERE/build; mkdir -p \$B/pf/targets/wasm32 \$B/app \$HERE/dist
cp \$PLATFORM/main.roc \$B/pf/main.roc
cp \$PLATFORM/targets/wasm32/host.wasm \$B/pf/targets/wasm32/host.wasm
cp \$ENGINE \$B/pf/Engine.roc
cp \$HERE/app/main.roc \$HERE/app/Jfb.roc \$B/app/
sed -i 's#platform "[^"]*"#platform "../pf/main.roc"#' \$B/app/main.roc
rm -f \$B/app.wasm
(cd \$B/app && \$ROC build --target=wasm32 --opt=\$OPT --no-cache --output=\$B/app.wasm main.roc)
cp \$B/app.wasm \$HERE/dist/app.wasm
cp \$PLATFORM/runtime.mjs \$HERE/dist/runtime.mjs
cp \$HERE/src/main.mjs \$HERE/dist/main.mjs
ls -la \$HERE/dist
EOF
 chmod +x $D/build.sh
 cat > $D/package.json <<EOF
{
  "name": "js-framework-benchmark-$name",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "main": "dist/main.mjs",
  "js-framework-benchmark": {
    "frameworkVersion": "0.0.1",
    "frameworkHomeURL": "https://github.com/lukewilliamboswell/roc-signals",
    "language": "WebAssembly"
  },
  "scripts": {
    "dev": "npm run build-prod",
    "build-prod": "bash build.sh"
  },
  "license": "UPL-1.0"
}
EOF
}
mk roc-d-each $P/p2each/platform-roc $P/p2each/src/Engine.roc "Phase 2 unified D+each Roc engine (p2each/src/Engine.roc)."
mk roc-d-p3copy $P/p3copy/platform-roc $P/p3copy/src/Engine.roc "D+each app on the Phase 3 column-copy workaround engine (p3copy/src/Engine.roc)."
mk roc-d-p3m $P/p3size/platform-roc $P/p3size/src/Engine.p3m.roc "D+each app on the Phase 3 size-optimised engine (p3size/src/Engine.p3m.roc), built --opt=speed."
