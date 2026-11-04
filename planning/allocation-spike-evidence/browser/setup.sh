#!/bin/bash
set -x
source /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/spike1/env.sh
J=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/jfb
cd $J && npm ci --no-audit --no-fund && npm run install-webdriver-ts && npm run install-server
cd $J/frameworks/keyed/solid && npm ci --no-audit --no-fund && npm run build-prod
for p in base:/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/base-tree s1:/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a7f367a813cf0c931 s2:/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a22147108dd3cc61d; do
  n=${p%%:*}; t=${p#*:}
  D=$J/frameworks/keyed/roc-signals-$n
  rm -rf $D; cp -r /home/lbw/Documents/Github/roc-signals/benchmarks/js-framework-benchmark/roc-signals-keyed $D
  sed -i "s/\"name\": \"js-framework-benchmark-roc-signals\"/\"name\": \"js-framework-benchmark-roc-signals-$n\"/" $D/package.json
  cd $D && npm ci --no-audit --no-fund && ROC_SIGNALS_ROOT=$t ROC_BIN=$ROC_BIN npm run build-prod
  ls -la $D/dist
done
echo SETUPDONE
