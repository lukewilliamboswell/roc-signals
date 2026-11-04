#!/bin/sh
R=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
P=/tmp/claude-1000/re/p1b
python3 $P/gen.py 600 200 $P/d/g600 $P/cur600
mkdir -p $P/d/t600
cp $P/d/Engine.roc $P/d/Decode.roc $P/d/timing.roc $P/d/g600/Gate.roc $P/d/t600/
( cd $P/d/t600 && $R build timing.roc --output=timing > build.log 2>&1 ) &
( cd $P/cur600 && /usr/bin/time -v $R build --target=x64musl --opt=speed --no-cache --output=cur main.roc > build.log 2>&1 )
wait
grep -E "found in|Elapsed" $P/cur600/build.log $P/d/t600/build.log
