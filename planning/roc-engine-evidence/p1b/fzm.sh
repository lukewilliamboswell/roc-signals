#!/bin/sh
# Usage: fzm.sh PATTERN DIR...  -- fz.sh each DIR, grep PATTERN
pat=$1; shift
for d in "$@"; do
  echo "== $d"
  /tmp/claude-1000/re/p1b/fz.sh "$d" | grep -E "$pat"
done
