#!/bin/bash
set -u
A=${1:?usage: paritydecoded.sh <engineA> <engineB> [corpus]}
B=${2:?}
CORPUS=${3:-$(dirname "$(readlink -f "$0")")/corpus.txt}
for e in "$A" "$B"; do [ -x "/mnt/fire/$e/run.sh" ] || { echo "no such engine: $e"; exit 1; }; done
total=$(grep -vc "^#\|^$" "$CORPUS"); pass=0; fail=0; n=0; empty=0
while IFS= read -r line; do
  case "$line" in ""|"#"*) continue;; esac
  n=$((n+1))
  a=$(printf "%s\n" "$line" | "/mnt/fire/$A/run.sh" 2>/dev/null 3>/dev/null)
  b=$(printf "%s\n" "$line" | "/mnt/fire/$B/run.sh" 2>/dev/null 3>/dev/null)
  [ -n "$a" ] && [ -n "$b" ] || { empty=$((empty+1)); }
  if A="$a" B="$b" python3 -c "
import json,os,sys
try: x=json.loads(os.environ[chr(65)]); y=json.loads(os.environ[chr(66)])
except Exception: sys.exit(2)
sys.exit(0 if x==y and x!=[] else 1)"; then
    pass=$((pass+1)); printf "[%3d/%3d] PASS  %.68s\n" "$n" "$total" "$line"
  else
    fail=$((fail+1)); printf "[%3d/%3d] FAIL  %s\n" "$n" "$total" "$line"
    printf "        %-16s: %.300s\n" "$A" "$a"
    printf "        %-16s: %.300s\n" "$B" "$b"
  fi
done < "$CORPUS"
echo
echo "=== decoded parity $A vs $B: $pass pass, $fail fail, of $n (empty bodies seen: $empty) ==="
[ "$fail" -eq 0 ] && [ "$empty" -eq 0 ]
