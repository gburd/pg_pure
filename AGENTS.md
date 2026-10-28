# Project instructions: pg_pure

Read this first, then `DESIGN.md`. `ROADMAP.md` is the only plan file, so do
not start a new plan or notes file. Domain steering (PostgreSQL, C, AWS) is
in `.agent-steering-domains.md`, which is local and not tracked.

## What this is

pg_pure makes Pure a procedural language in PostgreSQL 17, 18 and 19. It
embeds libpure from github.com/gburd/pure-lang (branch `libpure-embeddable`,
upstream PR #48). Two SQL languages come from one `pg_pure.so`: `pg_pureu`
(untrusted, superuser-only) works now; `pg_pure` (trusted) is an installable
stub until libpure gains a sandbox. We ultimately ship `pg_pure`.

## Where work runs

- **All builds, tests and measurements run on EC2 in the kiwi AWS account
  (us-east-2), never on floki.** Greg asked for this on 2026-10-27.
- The main dev box is Debian 13; FreeBSD boxes are launched per-test and
  torn down. Coordinates and the teardown script live under `/tmp/pgpure_*`
  on floki, never in the repo, and no AWS ID goes in the repo (pg_fts
  rule 28).
- Every resource gets the tags Owner=gburd, Purpose=pg_pure-dev and an
  Expires date. The dev box stops itself 12 hours after boot; push the stop
  time back if the work runs longer, and `start` it again after it stops.
- Resolve AMIs at launch time and record the AMI next to any number kept.
- Leave the kiwi account's other instances alone: they belong to other
  projects.
- libpure is built from the fork and installed under a prefix; pg_pure is
  built with `PURE_PREFIX` pointing there. On a JIT-enabled server (its
  `llvmjit` links a different LLVM major than libpure) either remove the
  server's JIT package or use the `-Bsymbolic` libpure (DESIGN.md 5/5a).
- libpure changes go to the fork, never into this repo as vendored code or
  patches.

## Rules that exist because they were broken

1. **A result needs evidence that the thing you meant to run actually
   ran.** In the first crash matrix, every case reported "0 crashes"
   because the Pure function did not exist in that database, so Pure never
   ran. A case counts only after its own output has been checked. pg_weave
   learned the same lesson nine times.
2. **Look for crashes in the server log, not in client exit codes.** The
   LLVM crash happens when the backend exits, after every query has
   succeeded. It shows up as "terminated by signal 11" in the log and as a
   different session's "terminating connection because of crash of another
   server process". Every test that runs Pure also checks the log.
3. **Every suite runs PostgreSQL JIT and Pure in the same backend, in both
   orders.** PGDG builds llvmjit against a different LLVM major version
   from libpure's. DESIGN.md section 5.
4. **A projected number is not a measurement.** Report what was measured,
   with the box, AMI, PostgreSQL version and number of runs. When in doubt,
   write "unmeasured".
5. **The Pure/PostgreSQL boundary rules in DESIGN.md section 4 are
   correctness invariants, not style.** No ERROR may longjmp through Pure
   frames, and no Pure exception may escape into PostgreSQL.
6. **Type conversions never lose information silently.** A value that does
   not fit is an ERROR. The prototype returned wrong numbers in three ways
   (DESIGN.md section 8).
7. **Test what you put in the docs.** Every Pure snippet in DESIGN.md and
   README was run on the box. Keep it that way: `strjoin` looked plausible
   and does not reduce.

## Code and repository

- PostgreSQL C style and pgindent. ASCII only in code, SQL, docs and commit
  messages.
- Commit messages follow PostgreSQL house style (see the steering file).
  No agent attribution.
- Stage files by explicit path. Do not commit agent artifacts (`.claude/`,
  `.kiro/`, `.direnv/`, `.mcp.json`, `.agent-steering-domains.md`, `_/`).
- Every new TAP test goes into `ci/gate.sh` in the same commit.
- When a published claim turns out wrong, the CHANGELOG says so under
  "Retracted".
