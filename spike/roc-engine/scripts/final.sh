#!/bin/bash
# final.sh -- rebuild and run every app's fuzz target on the final engine; collect summaries.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
: > $P/results/fuzz-final.txt
for A in form-builder kanban-board data-grid markdown-editor; do
  echo "######## $A" >> $P/results/fuzz-final.txt
  $P/fzrun.sh $A >> $P/results/fuzz-final.txt 2>&1
done
grep -E "^#|^== |passed|failed|crash" $P/results/fuzz-final.txt
