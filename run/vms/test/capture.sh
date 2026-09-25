#!/bin/bash
# Usage: capture.sh <engine> <corpus> <outfile>
# never point it at an existing golden: it truncates the outfile, and a golden cannot be re-collected
set -u
E=${1:?}; C=${2:?}; O=${3:?}
[ -x "/mnt/fire/$E/run.sh" ] || { echo "no such engine: $E"; exit 1; }
total=$(grep -vc '^#\|^$' "$C"); n=0; empty=0
: > "$O"
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  n=$((n+1))
  body=$(printf '%s\n' "$line" | "/mnt/fire/$E/run.sh" 2>/dev/null 3>/dev/null)
  [ -n "$body" ] || empty=$((empty+1))
  printf '%s\n%s\0' "$line" "$body" >> "$O"
  printf '[%3d/%3d] %6d bytes  %.60s\n' "$n" "$total" "${#body}" "$line"
done < "$C"
echo "=== captured $n records from $E into $O (empty bodies: $empty) ==="
[ "$empty" -eq 0 ]
