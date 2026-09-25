#!/bin/bash
#   ./parity.sh <engineA> <engineB> [corpus]
#   ./parity.sh sqlite_3.45 sqlite_3.45_next
set -u
A=${1:?usage: parity.sh <engineA> <engineB> [corpus]}
B=${2:?usage: parity.sh <engineA> <engineB> [corpus]}
CORPUS=${3:-$(dirname "$(readlink -f "$0")")/corpus.txt}

for e in "$A" "$B"; do
  [ -x "/mnt/fire/$e/run.sh" ] || { echo "no such engine: /mnt/fire/$e/run.sh"; exit 1; }
done

total=$(grep -vc '^#\|^$' "$CORPUS")
pass=0; fail=0; n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  n=$((n+1))
  a=$(printf '%s\n' "$line" | "/mnt/fire/$A/run.sh" 2>/dev/null 3>/dev/null)
  b=$(printf '%s\n' "$line" | "/mnt/fire/$B/run.sh" 2>/dev/null 3>/dev/null)
  if [ "$a" = "$b" ] && [ -n "$a" ]; then
    pass=$((pass+1))
    printf '[%2d/%2d] PASS  %s\n' "$n" "$total" "$(printf '%.70s' "$line")"
  else
    fail=$((fail+1))
    printf '[%2d/%2d] FAIL  %s\n' "$n" "$total" "$line"
    printf '        %-10s: %s\n' "$A" "$(printf '%.400s' "$a")"
    printf '        %-10s: %s\n' "$B" "$(printf '%.400s' "$b")"
  fi
done < "$CORPUS"

echo
echo "=== parity $A vs $B: $pass pass, $fail fail, of $n ==="
[ "$fail" -eq 0 ]
