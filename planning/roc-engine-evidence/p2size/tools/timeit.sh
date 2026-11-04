#!/bin/sh
# Usage: timeit.sh BINARY OUTFILE -- run the D timing driver under the shared lock, then summarise
flock /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/timing.lock timeout 300 "$1" > "$2"
echo "exit $?"
python3 -I /tmp/claude-1000/re/p2size/tools/summ.py "$2"
