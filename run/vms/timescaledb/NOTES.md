# timescaledb

- Pair each timescaledb version with the newest PostgreSQL major it supports. Derive the
  window from packagecloud's own index, never the vendor's table:

      curl -sSL https://packagecloud.io/timescale/timescaledb/debian/dists/<dist>/main/binary-amd64/Packages.gz

- Never build on PostgreSQL 17.1, 16.5, 15.9, 14.14, 13.17 or 12.21. Re-read Timescale's own
  list at every build.
- Pin `timescaledb-2-loader-postgresql-N` to the branch as well as
  `timescaledb-2-postgresql-N`.
- `diff` `fiddle.c`'s body against the postgres family's before believing a parity number:

      awk "/^<<'EOC' cat > .*fiddle\.c\$/{f=1;next} /^EOC\$/{f=0} f" <recipe> |
        awk '/^#include <stdio.h>$/{f=1} f'

- Give a cross-family `parity.sh` run the postgres corpus path.
- After a rebuild, check in a restored fiddle that `pg_stat_activity` shows the background
  worker launcher and scheduler, that every stock job is scheduled within a day of the
  restored clock, and that `add_continuous_aggregate_policy` creates its job.
- goldencheck scores 0 on this family by design. Read `run/vms/test/explaingolden.py`
  instead, and never overwrite `test/golden-node.txt`.
