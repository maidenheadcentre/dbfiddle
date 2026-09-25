# sqlserver

`sqlserver_2014`, `_2016`, `_2017` and `_2019` are frozen: view-only in the web app, no
sudoers line, no backend.

- Build `MSSQL_PID=Express`. Developer Edition must never serve the public site.
- Run setup in the guest, not in docker, while the host kernel is 5.10.
- Never replace the CPU template that masks invariant TSC with `clocksource=tsc` or
  `no-kvmclock`.
- Derive the CNG DRBG table RVA for every version and confirm it by effect, never by
  inspection. Never filter the search on the output-cache size. Gate the ceremony on the
  re-keyed count.
- Screen every snapshot: ~150 restores after the ceremony, and re-run the ceremony if any
  comes back empty.
- Build the arms of an experiment by `zfs send | recv` from one `@base`, never from separate
  ceremonies.
- Never write into `rootfs.ext4` after the ceremony. Rebuild instead.
- An unjailed restore runs `rm -f v.sock*` first.
- On an empty body, check the firecracker pid before anything else: alive and burning a CPU
  is a wedge.
- Gate an AdventureWorks load on rows and encoding, never on a table count.
- Keep `adventureworks/` byte-identical across the sample engines. Never pass
  `instawdb.linux.sql` through python text-mode I/O.
- Keep the shared files in `test/` identical across the family, apart from each
  `parity.sh`'s usage line.
