#!/bin/bash
# Sync sources into a fuzz dir and build it. Usage: fz.sh [DIR]   (default fuzz)
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
F=$D/${1:-fuzz}
for m in Engine Dom Jfb T1 T2 Canary TaskRow NestedEach; do
  [ "${NOSYNC_ENGINE:-}" = 1 ] && [ $m = Engine ] && continue
  cp $D/src/$m.roc $F/$m.roc
done
cd $F
/usr/bin/time -f "build %e s, %M KB" timeout 2400 /home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc build --fuzz --opt=${ROCOPT:-speed} main.roc --output=t > build.log 2>&1
tail -15 build.log | grep -v '^$'
