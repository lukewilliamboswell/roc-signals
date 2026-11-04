#!/bin/sh
T=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/tasks/be3dpm39a.output
a=0; b=0; c=0
while true; do
  if [ $a = 0 ] && [ -s $T ]; then echo "D600 timing done"; a=1; fi
  if [ $b = 0 ] && grep -q Elapsed /tmp/claude-1000/re/p1b/cur600/build.log; then echo "cur600 build finished"; b=1; fi
  if [ $c = 0 ] && grep -q Elapsed /tmp/claude-1000/re/p1b/cur1500/build.log; then echo "cur1500 build finished"; c=1; fi
  [ $a = 1 ] && [ $b = 1 ] && [ $c = 1 ] && exit 0
  sleep 10
done
