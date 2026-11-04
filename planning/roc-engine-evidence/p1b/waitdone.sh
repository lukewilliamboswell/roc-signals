#!/bin/sh
F=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/tasks/bl2iat282.output
until grep -q done $F; do sleep 10; done
echo "locked timing run finished"
