#!/bin/sh
P=/tmp/claude-1000/re/p1b
$P/run-cur.sh $P/cur150 curdev dev
$P/run-cur.sh $P/cur1500 curdev dev
$P/d/t600/timing > $P/d/t600/timing.txt
$P/d/t1500/timing > $P/d/t1500/timing2.txt
