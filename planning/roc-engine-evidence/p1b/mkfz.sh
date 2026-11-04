#!/bin/sh
# Usage: mkfz.sh NAME GATE_DIR  -- assemble a D fuzz target dir d/fz-NAME
D=/tmp/claude-1000/re/p1b/d
T=$D/fz-$1
rm -rf "$T"; mkdir -p "$T"
cp $D/Engine.roc $D/Decode.roc "$T/"
cp "$2/Gate.roc" "$T/"
sed 's#"../../p0a/fuzzpf/main.roc"#"../../../p0a/fuzzpf/main.roc"#' $D/fzmain.roc > "$T/main.roc"
/tmp/claude-1000/re/p1b/fz.sh "$T"
