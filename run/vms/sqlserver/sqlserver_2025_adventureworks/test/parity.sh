#!/bin/bash
#   ./parity.sh <engineA> <engineB> [corpus]
#   ./parity.sh sqlserver_2025_adventureworks sqlserver_2025_adventureworks_next
set -u
A=${1:?usage: parity.sh <engineA> <engineB> [corpus]}
B=${2:?usage: parity.sh <engineA> <engineB> [corpus]}
CORPUS=${3:-$(dirname "$(readlink -f "$0")")/corpus.txt}

for e in "$A" "$B"; do
  [ -x "/mnt/fire/$e/run.sh" ] || { echo "no such engine: /mnt/fire/$e/run.sh"; exit 1; }
done

# the retry is for the sosschedmon.cpp:219 defect only: never carry it to another family
retried=0
run1() {   # engine, line -> body, retried once if empty
  local out
  out=$(printf '%s\n' "$2" | "/mnt/fire/$1/run.sh" 2>/dev/null 3>/dev/null)
  if [ -z "$out" ]; then
    retried=$((retried+1))
    out=$(printf '%s\n' "$2" | "/mnt/fire/$1/run.sh" 2>/dev/null 3>/dev/null)
  fi
  printf '%s' "$out"
}

total=$(grep -vc '^#\|^$' "$CORPUS")
pass=0; fail=0; n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  n=$((n+1))
  a=$(run1 "$A" "$line")
  b=$(run1 "$B" "$line")
  if [ "$a" = "$b" ] && [ -n "$a" ]; then
    pass=$((pass+1))
    printf '[%3d/%3d] PASS  %s\n' "$n" "$total" "$(printf '%.66s' "$line")"
  else
    fail=$((fail+1))
    printf '[%3d/%3d] FAIL  %s\n' "$n" "$total" "$line"
    printf '        %-24s: %s\n' "$A" "$(printf '%.400s' "$a")"
    printf '        %-24s: %s\n' "$B" "$(printf '%.400s' "$b")"
  fi
done < "$CORPUS"

echo
echo "=== parity $A vs $B: $pass pass, $fail fail, of $n ($retried empty-body retries) ==="
[ "$fail" -eq 0 ]
