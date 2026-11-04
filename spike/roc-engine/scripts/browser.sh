#!/bin/bash
# browser.sh APP [WASM_DIR] -- replay APP's original .scm specs in headless Chrome
# against the Wasm build in $P/wb-APP (scripts/wbuild.sh). Results JSON in $P/results.
. "$(dirname "$0")/env.sh"
A=$1; D=${2:-$P/wb-$A}
SPECDIR=${SPECDIR:-$R/../../examples-web/$A/specs}
python3 $R/tools/scm2json.py $SPECDIR $P/$A.json > /dev/null
NODE_PATH=$PUPPETEER_NODE_PATH timeout ${BTIMEOUT:-900} node $R/browser/replay.mjs $D $P/$A.json $P/results/browser-$A.json
