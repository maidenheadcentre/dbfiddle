#!/usr/bin/env python3
"""Account for the differences between a node golden and the C runner.

goldencheck reports 0/N on BOTH of its columns for a node-to-C conversion, which on its
own is indistinguishable from "the new runner is broken". It is not: node's divergences
are in the markdown TEXT, so decoding cannot rescue them either.

This applies node's two MECHANICAL quirks to the C runner's output and re-compares, so
what is left over is a short list to explain one record at a time rather than all of them:

  1. node wrote "| :---|" - a leading space in the header separator row
  2. node put the blank line BEFORE the status fence; the C runner puts it after

Anything still differing must fall into one of node's four remaining divergences, and each
is printed with a guess at which:

  - a multi-statement batch: node's pq.exec() returned only the LAST result
  - alignment: node right-aligned float4/float8 and left-aligned money, the C runner does
    the opposite on all three
  - an empty batch: node emitted an empty error fence where the C runner emits a newline
  - node fenced on resultStatus rather than on a per-result error message

Anything the classifier cannot place is printed as UNEXPLAINED, and each of those is a
possible regression that has to be read.

  explaingolden.py <golden-file> <engine>
"""
import json, re, subprocess, sys

golden, engine = sys.argv[1], sys.argv[2]

SEPROW = re.compile(r'^\|(?=[-:])', re.M)
FENCE = re.compile(r'(?m)^> ```')


def nodeify(md: str) -> str:
    """Turn one C-runner markdown record into what node would have emitted."""
    md = SEPROW.sub('| ', md)                    # 1. leading space in the separator row
    # 2. the blank line moves from after the fence to before it
    if md.endswith('\n\n'):
        md = md[:-1]
    m = FENCE.search(md)
    if m and m.start() > 0 and md[m.start() - 1] == '\n' \
       and md[m.start() - 2:m.start() - 1] != '\n':
        md = md[:m.start()] + '\n' + md[m.start():]
    return md


def classify(line, old, new):
    if len(old) != len(new):
        return 'BATCH-COUNT MISMATCH - same batches in, different record count out'
    reasons = []
    if re.search(r';\s*\S', line):
        reasons.append('multi-statement batch (node kept only the last result)')
    if re.search(r'float4|float8|::money|Infinity', line):
        reasons.append('alignment (node: float right, money left)')
    if re.search(r'\[""\]|\["\s+"\]|"",', line):
        reasons.append('empty batch (node emitted an empty error fence)')
    return '; '.join(reasons) if reasons else 'UNEXPLAINED - read this one'


records = open(golden, 'rb').read().split(b'\0')
same = 0
leftover = []
for rec in records:
    if not rec.strip():
        continue
    line, _, old = rec.decode().partition('\n')
    new = subprocess.run(['/mnt/fire/%s/run.sh' % engine], input=line + '\n',
                         capture_output=True, text=True).stdout.strip()
    try:
        o, n = json.loads(old), json.loads(new)
    except Exception:
        leftover.append((line, 'UNPARSEABLE', old[:220], new[:220]))
        continue
    if len(o) == len(n) and all(nodeify(b) == a for a, b in zip(o, n)):
        same += 1
    else:
        leftover.append((line, classify(line, o, n),
                         json.dumps(o)[:260], json.dumps(n)[:260]))

total = same + len(leftover)
bad = [x for x in leftover if 'UNEXPLAINED' in x[1] or 'MISMATCH' in x[1] or x[1] == 'UNPARSEABLE']
print("=== %s vs %s ===" % (engine, golden))
print("    explained by the separator space + the fence blank line alone : %d / %d" % (same, total))
print("    needing one of node's other four divergences                  : %d" % (len(leftover) - len(bad)))
print("    UNEXPLAINED - each is a possible regression                   : %d" % len(bad))
for line, why, o, n in leftover:
    print("\n--- %s\n    [%s]" % (line[:110], why))
    print("    node: %s" % o)
    print("    C   : %s" % n)
sys.exit(1 if bad else 0)
