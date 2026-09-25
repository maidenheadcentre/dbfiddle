# documentdb_0.114

- Inserts into a collection that already exists crash the backend on PostgreSQL 18.6 and
  later. Do not pin this engine to 18.4.
- `parity.sh` cannot see the crash. `documentdb_0.116/test/crashcheck.sh` can.
