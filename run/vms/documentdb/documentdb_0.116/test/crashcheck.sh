#!/bin/bash
#   ./crashcheck.sh <engine> [corpus]
#
# parity.sh passes a crash that is deterministic in both builds; this fails on a dead backend.
set -u
E=${1:?usage: crashcheck.sh <engine> [corpus]}
CORPUS=${2:-$(dirname "$(readlink -f "$0")")/corpus.txt}
[ -x "/mnt/fire/$E/run.sh" ] || { echo "no such engine: /mnt/fire/$E/run.sh"; exit 1; }

n=0; bad=0
while IFS= read -r line; do
  case $line in ''|'#'*) continue;; esac
  n=$((n+1))
  out=$(printf '%s' "$line" | /mnt/fire/$E/run.sh)
  if [ -z "$out" ]; then
    echo "EMPTY BODY  line $n: $line"; bad=$((bad+1)); continue
  fi
  case $out in
    *'server closed the connection'*|*'no connection to the server'*|*'InternalError'*|*'terminated abnormally'*)
      echo "CRASH       line $n: $line"
      echo "            -> $(printf '%s' "$out" | tr -d '\n' | cut -c1-160)"
      bad=$((bad+1));;
  esac
done < "$CORPUS"
echo "$n lines, $bad crashed or empty"
[ "$bad" -eq 0 ]
