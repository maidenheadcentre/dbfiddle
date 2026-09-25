# dbfiddle back end

`run/` is the machinery that actually runs fiddles. The web app (site, lambdas, fiddle DB
schema) is the rest of this repo, and the README covers it.

`run/vms/<family>/<engine>/install.sh` is a self-contained, commented recipe for one
engine, and is the truth about that engine. Engine directories are grouped by family, but the
directory name is the engine code, which is also the ZFS dataset (`tank/fire/mariadb_10.2`)
and the deploy path (`/mnt/fire/mariadb_10.2`) — those stay flat on the server; only the repo
is nested. `run/vms/test/` is shared tooling, not a family.

## Principles for this file

Check any edit against these. If a paragraph does not fall under *What belongs*, delete it.

**What belongs**

- A map of the system — the shape of the request path, enough to orient before you know
  which file to open.
- Instructions.
- Rules about production risk: what needs authorisation, what counts as proven.
- Steps performed from here against the fiddle DB.

**What does not**

- Justification. State the instruction. Not the argument for it, not the mechanism behind
  it, not the alternatives already ruled out, not what it looked like when it went wrong.
- Measurements, unless the decision they feed is still open.
- Anything a recipe, corpus or script already says — per-engine tables, versions, sizes,
  counts, corpus contents, parity scores. The recipe is the truth.
- History — dates, build durations, soak results, who decided what and when. Git is the
  record.
- Anything not established. No hedges: if it is not verified it is Open work, or it is
  nothing.
- Vendor facts, except where one bears on a decision that would otherwise be got wrong.
- Web-app internals.

**An instruction that only compensates for a defect is not an instruction.** It is a defect
record: one line of open work with its fix.

**Where a note goes.** Three levels, and these principles apply to all of them:

- `CLAUDE.md` — the system: principles, the map, instructions, production risk.
- `run/vms/<family>/NOTES.md` — what is true of the family.
- `run/vms/<family>/<engine>/NOTES.md` — what is true of that version only.

A fact lives at the highest level where it is true, and only there. If it holds for every
engine it is an instruction in this file, not a note.

## How a fiddle runs

    browser → dbfiddle.uk (AWS lambda) → run.dbfiddle.uk
            → cumbria2 192.168.43.2 /var/www/html/index.php (proc_open sudo /mnt/fire/<engine>/run.sh)
            → /mnt/fire/<engine>/run.sh: a shim that execs the shared runner
            → /mnt/fire/run.sh: zfs clone @base → firecracker restore → collect output → destroy clone

`run.sh` runs as root via a per-engine NOPASSWD sudoers line. Apache's cwd is `/`.

Every snapshot engine's `/mnt/fire/<engine>/run.sh` is a shim; the runner is one shared copy
at `/mnt/fire/run.sh`, deployed from `run/runner/` by its own `deploy.sh`. The shim exists
because the sudoers line names that path, and it passes its own directory name as the
runner's only argument. **The engine name must come from the shim's location, never from the
caller** — a sudoers `Cmnd` with no argument spec permits any arguments, so a shim that
passed `"$@"` through would let the caller choose which engine to run. The runner derives
`fsize` from the rootfs it is about to boot, so no snapshot engine carries a resource limit
of its own. **Deploy the runner before a from-scratch build**, or the new engine's first
fiddle execs a file that is not there.

cumbria2's dispatcher takes any `type` matching `^[a-z0-9._]+$`; **sudoers is the whitelist**:
a name with no sudoers line gets 400, and a request fails with 502 when sudo exits non-zero
or the body is empty. A broken engine returns 502, not a blank 200. The dispatcher also holds
the per-engine concurrency limit — six lock slots, 503 when full — a 25s deadline, which
returns 504, and a 2.5M cap on the body, counted as it is read, which returns 413. The cap is
set by what the fiddle page can render, not by the host's memory.

**The timeout ladder increases outward and stays under the lambda's 30s**: `run.sh` 20s,
cumbria2 25s, lambda 30s. Keep the gaps when changing any of them, so each layer returns its
own error instead of being killed by the layer above.
**cumbria2's `$cap` must match `run.sh`'s wait** — it is what separates a timeout from a
broken engine. A timeout is 504 either way: logged `TIMEOUT` when the child used its whole
allowance, `DEADLINE` when the dispatcher gave up on it first. 502 is a fast failure.

The dispatcher is in `run/cumbria.md`. **Deploy from the heredoc, never by editing the live
file, and `diff` the two afterwards.**

Do not give `run.sh` a meaningful exit status.

A sample route is a separate engine, not a flag: `type`+`sample` resolves to the dataset
`<type>_<sample>`, with its own recipe, dataset and sudoers line.

`run.sh` copies `/mnt/fire/fiddlestats/current.img` into the chroot of any engine whose
dataset has a `fiddlestats/` directory.

Nothing runs on KVM. Everything is firecracker.

## Engine identity

An engine code is `engine_code` + `version_code` from the fiddle DB's `version` table, and
the fiddle DB is the authority. **`version_code` is a label, not a prefix of the vendor's
version** — `oracle_26` serves 23.26.x, and the granularity differs per engine and within a
family (`postgres_18`, `postgres_9.6`, `oracle_11.2`, `oracle_23c`). A recipe is told its
version_code; the build records what it actually produced, so a human can confirm the two
still correspond.

**Build the newest release matching `version_code`. Do not pin.**

**Fetch from a source that names what it serves, and float against it.** No digests: trust
the identifiable source. Where a vendor publishes only an unversioned pointer, use a source
that is versioned instead — Oracle's container registry carries fully-qualified tags for
lines whose RPM URLs do not.

## Engine models

**Every engine is snapshot restore.** A `@base` snapshot holds a pre-booted guest
(`mem` + `vmstate` + `rootfs.ext4`), restored per request.

A batch may be a `[text, language]` pair rather than a string, in which case the runner runs
it in **its own interpreter process** instead of the engine. The language rides with its own batch, 
so there is no field count to align. Batches share the guest but never an interpreter, so nothing 
one batch defines survives into the next.

**Multilingual always means a language running outside the database.** python, node, bash, c
and mongosh are processes in the guest beside the engine. In-database languages like
plpython3u are normal engine features reached from a SQL batch, not multilingual. Anything a
multilingual batch sees of the database it sees through its own connection.

**Stay idiomatic to the engine and its client library.** Where either has a default, take it.
Never commit, retry or tidy up on a user's behalf.

**No runner manages transactions**; each takes its client library's default, so the engines
differ: postgres commits at the end of a batch (one `PQsendQuery` is an implicit transaction
block), sqlserver, mysql and duckdb per statement, db2 autocommit explicitly, oracle never at
all. So what a multilingual batch can see differs by engine.

Batches and output cross over vsock: **the guest listens on 9001/9002 and the host dials in,
never the reverse.** The seed ioctls and clock set live in `/vsock serve`, post-restore and
before anything connects. `vsock.c` and `listener.pl` are shared verbatim, so per-engine work
is `config.json`'s vsock block and a few lines of `fiddle.sh`.

Snapshot datasets are created `recordsize=16K`, `compression=lz4`. Set recordsize after the
rootfs is built and before the snapshot ceremony.

Add `no-kvmapf` to `boot_args` if a guest shows intermittent 45–60s stalls.

Run a throwaway invocation of the runner before the snapshot is taken. **The warm-up must
never read anything volatile** — clock, PRNG, uuid, rowid — and per-fiddle seeding must stay
out of the `--warmup` path, or the value is frozen into `mem` and shared by every fiddle.

`batches.json` and `output.json` live in the guest's rootfs, alongside the database's own WAL,
logs and temp files.

## Randomness

A restored guest is byte-identical every time. `/vsock serve` reseeds the guest CRNG from 32
fresh host bytes after every restore and before anything connects, so `getrandom()` is a
sound entropy source inside a runner. The clock is not: `run.sh` sets it to a whole second.

**Whether an engine needs a per-session reseed is a property of the build, not of the product
or the version number. Measure every engine**, against its own unseeded build as the control.

Verify sequentially **and concurrently** — concurrent pairs are what catch a coarse-clock
seed. A probe must adapt to the version: a function that does not exist errors the whole
select, and comparing two empty strings reads as a 100% collision rate. Assert the extractor
returned non-empty values before believing any count. Re-measure after a runner change.

## The JSON emitter

**New runners use the raw emitter**; the php-faithful one is legacy and is being retired. The
two differ only in `json_emit_string`: php-faithful escapes `/` as `\/` and every non-ascii
codepoint as `\uXXXX`; raw passes validated UTF-8 through.

The only thing it decides is byte-comparability. A corpus is byte-portable only between
engines sharing an emitter, so **convert a family, never one member of one.** Prove a
conversion with `paritydecoded.sh` (must pass) alongside a plain byte `parity.sh` (must
fail).

## Corpora

Every engine has `test/corpus.txt` and `test/parity.sh`. `parity.sh` is engine-agnostic — two
engine names and an optional corpus path.

- A corpus must contain nothing volatile. It is a differential test: it does not care what
  the right answer is, only that a change did not alter it.
- **Validate a corpus live-vs-live before using it differentially.** An unvalidated corpus
  proves nothing when it passes.
- Keep a family's corpus byte-identical across its members, or a cross-version run stops
  measuring versions.
- Extend a corpus when you want it to see a version boundary. A clean cross-version score
  measures corpus scope, not the versions. After adding a boundary case, re-run the other
  pairs: a line that separates the new pair must not quietly separate an old one.
- A language engine also has `test/corpus-lang.txt`. Compare it same-engine for
  non-volatility, and between two language-capable builds for regressions.

## Building and swapping

Never edit a live engine in place. Build a new dataset, prove it, then swap names.

    zfs send tank/fire/<eng>@base | zfs recv tank/fire/<eng>_next   # NOT zfs clone
    zfs destroy tank/fire/<eng>_next@base
    # build in _next: install run.sh FROM GIT, then edit rootfs / rebuild the guest snapshot
    zfs snapshot tank/fire/<eng>_next@base
    # prove it with a real fiddle under its own name, then:
    zfs rename tank/fire/<eng> tank/fire/<eng>_prev
    zfs rename tank/fire/<eng>_next tank/fire/<eng>
    # rollback = the reverse two renames.  retire later:
    zfs destroy -R tank/fire/<eng>_prev

- Use `send | recv`, never `zfs clone`, so `_next` is independent.
- `@base` holds a frozen copy of the shim. Install it from git, not from `.zfs/snapshot/`.
  Check with `zpool history tank | grep <eng>_next`. A dataset restored from an old `@base`
  may hold a whole pre-shim `run.sh`, which still works and so fails silently as a fossil:
  it pins that engine to its own stale copy of the runner.
- Check `origin` before destroying anything: `zfs list -r tank/fire -o name,origin`.
- Retire a `_prev` once its swap has settled.
- Run the ceremony with cwd set to the dataset directory, in a subshell — `config.json`'s
  paths are relative and the snapshot records them relative.
- A boot-arg change needs a full ceremony: `_next` must boot fresh from the edited config and
  produce new `mem`/`vmstate`. Confirm from the guest's own console log.
- `zfs rename` may print `snapshot delimiter '@' is not expected here`. It is cosmetic and
  returns rc=0.

A test harness is a change to an engine: give it its own dataset (`<eng>_timed`, `<eng>_ctl`)
built the same way, and never swap it in.

A from-scratch rebuild driver deviates from a literal recipe run in three ways: `<eng>` →
`<eng>_next` substitution, the sudoers line skipped, and the interactive `docker run --rm -ti`
block run non-interactively. Derive the driver's line ranges with `grep -n` on distinctive
lines, never hardcode them. Anchor the container block's end on the last thing it does, not
on the first standalone `exit` — the heredocs inside it contain their own.

Pipe `install.sh`'s heredocs through the name substitution rather than retyping them.

**Porting a recipe to another version is an audit, not a substitution.** Check every
compile-time flag and every API the runner calls against that version's own sources: gcc
accepts an unknown `-D` in silence, so a wrong flag compiles, passes its gate, takes a
snapshot and serves fiddles while not doing what it says.

**Check the upstream repo carries what you assume.** A frozen vendor repo does not have a
dist for every release, and a suite can ship a package's scripts without its binary.

**Never derive a build driver by running sed over another build driver.** The driver's whole
job is a name substitution, so it contains the engine name as literal text; substituting over
it rewrites the inner rule to match nothing, and the recipe then runs unsubstituted **against
the live engine**. Check before running it — any hit is the live name:

    grep -c '<eng>[^_]' install.next.sh    # must be 0

## Production risk

- **Whatever is swapped into production must be reproducible from `install.sh`.**
- **Promoting an engine that was not built by a full from-scratch run of `install.sh` requires
  explicit authorisation, per swap.** Build it and prove it however you like — that is all
  reversible and invisible to production — then stop at the two renames and ask.
- Updating `install.sh` to match a mutated copy is a claim, not evidence. Say so rather than
  calling the engine reproducible.
- Changes that cannot be expressed as a copy mutation — removing packages the DOCKERFILE
  installs — need a DOCKERFILE change and a rebuild.
- A from-scratch rebuild pulls current OS packages, so the result is a new build that also
  has your change. Check the engine's reported version afterwards with one fiddle.
- Do not apply cumulative updates to a running engine.
- **A guest is untrusted, and root inside it is assumed.** A cap that lives in the runner binds
  a runaway query, not an attacker; the host must impose its own, and impose it by counting
  bytes rather than by parsing what the guest sent.

## Sizing the rootfs

**Target 50–100M free**, and it is a target, not a floor to exceed. A fiddle is a
demonstration; free space is both the working room a fiddle gets and the per-fiddle disk-churn
cap.

- Use `mkfs.ext4 -m 0` so the free count means what it appears to.
- Size at `du + ~28M + target` on a modern base, `du + ~68M + target` on buster or stretch.
  Below ~512M mke2fs picks 1024-byte blocks and the overhead is ~8M.
- Check the headroom on every rebuild, with `dumpe2fs -h` **after the umount**, parsing
  `Block size:` rather than assuming 4K. `dumpe2fs` reads the superblock without mounting, so
  it is safe against a live engine's `.zfs/snapshot/` copy. Do not mount it.
- A gate belongs after the ceremony, since that is the free space a fiddle's clone gets, and
  must name its own rootfs. Read it through a read-only `norecovery` mount and `df`, never
  `dumpe2fs`.
- Post-ceremony headroom far above the pre-ceremony reading means the docker layer tar
  inflated sparse files. Punch them in the builder container before the tar, and tar with `-S`.

## Registering an engine or version

- **cumbria2:** add the sudoers line. Without it, every request is 400.
- **fiddle DB:** `select admin.new_version('<engine>','<version>','<version_code>');` through
  `scripts/db.sh`. A version that already exists may be *disabled* rather than absent — check
  `version_is_active` first; if it is false, `update` it rather than inserting.
- Moving `engine_default_version_code` needs the engine's default fiddle to still run on the
  new version **and** to have been saved against it — run it through `POST /run`, then check
  the homepage link for that engine resolves.

Adding a version under an existing engine code is much cheaper than a new engine code:
`engine_default` is a column on `engine`, not `version`, so a new version shares the existing
default fiddle.

Registration needs no ssh into the devcontainer — `.devcontainer/.env` works as a docker
`--env-file`, so any container with `postgresql-client` can use it. Pass the password through
`PGPASSWORD`, never in the conninfo. Access depends on the AWS security-group rule that
`scripts/firewall.sh` points at the current public IP.

## Retired KVM VMs

Every VM under `/mnt/vms` is retired: its definition renamed to `<vm>.xml.retired`, its zvol
kept, so renaming it back and `vcreate <vm>` resurrects it. VM names do not match engine
codes — `fiddle-oracle21xe`, `fiddle-postgres10`, `fiddle-db2xc111`.

## Creating fiddles on the live site

`POST /run` runs the batches against the real engine, saves the fiddle, and returns its code
as base64url text. The URL is then `https://dbfiddle.uk/<code>`:

    code=$(curl -s -X POST 'https://dbfiddle.uk/run?engine=sqlserver&version=2025' \
             -H 'Content-Type: application/json' -d '["select @@version"]')
    echo "https://dbfiddle.uk/$code"

`engine` and `version` are the two halves of the engine code either side of the underscore.
Add `&sample=adventureworks` or `&sample=sakila` for the sample routes. The body is the same
JSON array of batch strings `run.sh` takes.

Posting the same batches twice returns the same code and replaces the stored output, so a
saved fiddle is not an archive. Vary the SQL if you want two URLs to compare.

## Verification

Finish with a real fiddle, not a smoke test of the moving parts, and assert the body:

    echo '["select 1 from dual"]' | /mnt/fire/oracle_26/run.sh   # must print a markdown table

Then check the production path end to end through `run.dbfiddle.uk`, and read the body.

`run.sh` and `listener.pl` are read live, per request, so deploying either takes effect on the
next fiddle across every engine at once — there is no build to fail first. Rollback is the
rename back to `run.sh.prev`.
**Canary one engine and run several fiddles before rolling out, then run one per family
afterwards.** Several, because a truncated-body fault is intermittent and a single pass can
succeed by luck; and a small result is the sensitive case, since a whole short body can fit
inside a lost buffer.

The shim lives only in the recipes and in each dataset, so changing it means rewriting all the
recipes *and* installing all the live copies — a recipe alone takes effect at a rebuild.
Nothing ships it, because nothing should need to: it is one `exec` line.

## Never

- **`zfs rollback` anything under `tank/fire`.** It reverts every file in the dataset,
  including the live `run.sh`.
- **Point a hand-written or modified `run.sh` at a live engine dataset**, measuring included.
- **Run any part of a recipe under a live engine's name**, including the front half to size an
  image. To size an image safely, extract only the DOCKERFILE and build that.
- **Restore a host-side script from `.zfs/snapshot/`.** Git is the source of truth.
- **Overwrite a live `run.sh` without keeping the old one.**
- **`cd` into an engine directory before running things.**
- **`zfs destroy <eng>@base` to refresh a snapshot.** Rebuild via `send | recv` + swap.
- **Swap an engine into production without explicit authorisation**, unless it was built by a
  full from-scratch run of `install.sh`.
