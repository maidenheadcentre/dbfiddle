# postgres

Every recipe is one of three shapes.

- **10–19** install from apt.postgresql.org onto debian and boot systemd.
- **9.3–9.6** compile from source on alpine and boot openrc.
- **8.4** installs from archive.debian.org onto debian squeeze and boots sysvinit.

Never overwrite `test/golden-node.txt` (9.3–9.6) or `test/golden-php.txt` (8.4). Replay them
with `run/vms/test/goldencheck.sh`.
