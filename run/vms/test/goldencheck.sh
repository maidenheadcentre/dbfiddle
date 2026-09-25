#!/bin/bash
#   goldencheck.sh <golden-file> <engine>
set -u
G=${1:?usage: goldencheck.sh <golden-file> <engine>}
E=${2:?}
[ -x "/mnt/fire/$E/run.sh" ] || { echo "no such engine: $E"; exit 1; }
total=$(tr -cd '\0' < "$G" | wc -c)
n=0; bytesame=0; decodesame=0; bad=0; empty=0
while IFS= read -r -d '' rec; do
  n=$((n+1))
  line=${rec%%$'\n'*}
  old=${rec#*$'\n'}
  new=$(printf '%s\n' "$line" | "/mnt/fire/$E/run.sh" 2>/dev/null 3>/dev/null)
  [ -n "$new" ] || empty=$((empty+1))
  b=0; d=0
  [ "$old" = "$new" ] && b=1 && bytesame=$((bytesame+1))
  if A="$old" B="$new" python3 -c "
import json,os,sys
try: x=json.loads(os.environ['A']); y=json.loads(os.environ['B'])
except Exception: sys.exit(2)
sys.exit(0 if x==y and x!=[] else 1)"; then d=1; decodesame=$((decodesame+1)); fi
  if [ "$d" -eq 0 ]; then
    bad=$((bad+1))
    printf '[%3d/%3d] DECODE-DIFF  %s\n' "$n" "$total" "$line"
    printf '        old: %.300s\n' "$old"
    printf '        new: %.300s\n' "$new"
  else
    printf '[%3d/%3d] decoded-ok %s  %.58s\n' "$n" "$total" \
      "$([ $b -eq 1 ] && echo 'bytes-same' || echo 'BYTES-MOVED')" "$line"
  fi
done < "$G"
echo
echo "=== $E vs $(basename "$G"): $n records"
echo "    byte-identical  : $bytesame / $n"
echo "    decode-identical: $decodesame / $n   (differences: $bad, empty bodies: $empty)"
[ "$bad" -eq 0 ] && [ "$empty" -eq 0 ]
