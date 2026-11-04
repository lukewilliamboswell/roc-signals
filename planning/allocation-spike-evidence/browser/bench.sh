#!/bin/bash
# Runs after setup.sh. Starts the local server, checks keyedness, runs the official driver.
set -e
J=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/jfb
F="keyed/solid keyed/roc-signals-base keyed/roc-signals-s1 keyed/roc-signals-s2"
cd $J; (npm start > /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/server.log 2>&1 &) ; sleep 5
cd $J/webdriver-ts
npm run isKeyed $F
cd $J
npm run bench -- --framework $F --chromeBinary /usr/bin/google-chrome --headless true --count 15 --benchmark 01_ 02_ 03_ 04_ 05_ 06_ 07_ 08_ 09_ | tee /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/bench.log
python3 -I /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/summarize.py $J/webdriver-ts/results | tee /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/jfb/ratios.txt
