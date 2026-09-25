# yugabytedb

- The recipes do not share a base. Check before copying anything between them.
- 2024.2 and 2025.2 name their release. Re-derive it at every rebuild.
- Byte-compare 2.6, 2.8, 2.18 and 2024.2 against `postgres_11`, and 2025.2 against
  `postgres_15`, giving `parity.sh` the postgres corpus path. Establish which PostgreSQL
  generation a new engine is before anything else.
- From 2024.2 on, set `reject_writes_min_disk_space_mb` on the master as well as the tserver,
  and on the start that creates the cluster.
- Addresses are literal `127.0.0.1`, never `$(hostname)`.
- goldencheck scores 0 on this family by design. Read `run/vms/test/explaingolden.py`
  instead, and never overwrite `test/golden-node.txt`.
