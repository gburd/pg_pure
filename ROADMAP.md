# pg_pure roadmap

This is the only plan file. The design and its reasons are in `DESIGN.md`,
the working rules in `AGENTS.md`. Each phase ends with a gate. A phase is
done when its gate has run on the EC2 box and the output shows that every
test in it actually ran.

## Phase 0: libpure prerequisites (in github.com/gburd/pure-lang)

Needed only for a PostgreSQL that is itself linked against a DIFFERENT LLVM
major than libpure (the stock PGDG case: server on LLVM 19, libpure on
LLVM 21). A server built without LLVM, or against the same LLVM major, does
not need this; DESIGN.md section 5a. The fix is proven out on the box
(`~/src/pure-hidden`), so phase 0 here is about landing it in the fork.

- [x] 0.1 (proven, not yet upstreamed) Stop libpure exporting LLVM symbols:
      link with `-Wl,-Bsymbolic` and a version script hiding `*4llvm*`, and
      link `pure` directly against libLLVM. Result: 0 `llvm::` exports,
      libpure `make check` 95/95, `make check-embed` passes, and the pg_pure
      extension runs the crash matrix 0-crash on a JIT-on PG 18 server.
      Still to do: land it in the fork (branch off `libpure-embeddable`) and
      add the `grep -c 'llvm::' == 0` assertion to `make check-embed`.
- [ ] 0.2 Commit the reproducer (`jitmix.sh`: PostgreSQL JIT plus Pure in
      one backend, in both orders; saved in `_/probes/jitmix.sh`) to the
      fork under `test/`. It must fail on the stock libpure and pass on the
      fixed one.

Gate: libpure `make check` (95 passed) and `make check-embed`; the
reproducer shows 0 crashes with the fix and 2 without it, on a PGDG server
(LLVM 19) with an LLVM-21 libpure.

## Phase 1: the extension (pg_pureu now, pg_pure on top)

- [x] 1.1 Repository skeleton: PGXS `Makefile` (with `dist` and
      `check-ascii`), `pg_pure.control` and `pg_pureu.control`, their
      `--0.1.sql` scripts, `sql/` with `expected/`, README, LICENSE,
      META.json (two provides), CHANGELOG, `ci/` (announce + noop), and the
      CI and release workflows. Still to add: a `t/` TAP suite.
- [x] 1.2 Port the prototype as `pg_pure.c` and fix the six defects in
      DESIGN.md section 8. Each fix has a regression case in
      `sql/pg_pureu.sql`; all pass on PG 17, 18 and 19.
- [x] 1.3 Type mapping: scalars, exact numeric (bigint and rational, with a
      verified round-trip), range checks, text-only text results, NULL,
      numeric via math. Still to do: arrays as lists, composites as records,
      other types through text I/O, a UTF-8 conversion for other encodings.
- [x] 1.4 The `sql` namespace: `query`, `exec`, `notice`, `warning`,
      `null`, `error` carrying SQLSTATE. (Parameters to `query`/`exec` are
      designed but not yet implemented; the body still builds its own SQL
      string.)
- [x]   The two trusted/untrusted handler pairs (`pg_pure`/`pg_pureu`), the
      DO inline handler, the validator, and `using` lines pulled to the top
      of a body.
- [x] 1.9 Cross-platform: Linux (Debian 13) PG 17/18/19 and FreeBSD 14.5
      PG 17 both build against the fork's libpure and pass the suite with 0
      crashes. Windows ruled out with reasons (DESIGN.md section 10).
- [ ] 1.4a Parameterized `sql::query (q, p1, ...)` / `sql::exec` (send
      parameters, never splice).
- [ ] 1.5 Set-returning functions (lists and lazy streams into a
      tuplestore), triggers (`new`, `old`, `tg`), procedures.
- [ ] 1.6 Preloading: the `_PG_init` warm-up code exists but is not yet
      tested end to end; confirm backends inherit it and measure.
- [ ] 1.7 TAP tests: crash safety (JIT plus Pure in both orders, with and
      without preload, checked in the server log -- the manual matrix is
      0-crash, 3 runs each, on PG 18); cancel and `pg_terminate_backend`;
      8 concurrent backends; RSS over 1M calls stays flat; a LATIN1
      database.
- [ ] 1.8 A cassert build of PostgreSQL from source on the box (and, once
      Greg's LLVM-21 work lands, a server whose llvmjit matches libpure's
      LLVM major -- the matched-major no-clash case, DESIGN.md 5a).

Gate: `ci/gate.sh` passes installcheck and TAP on PG 17 and PG 18, plus
the cassert leg; the server log has 0 "terminated by signal" lines and 0
TRAP lines; `make check-ascii` passes.

## Phase 2: depth

- [ ] 2.1 Prepared plans, either cached per query string or as an explicit
      `sql::prepare`.
- [ ] 2.2 `sql::stream q`: a lazy stream backed by a cursor. Forcing it
      after its call has returned must throw, never crash.
- [ ] 2.3 bytea (choose between a blob and a byte matrix), domains, and an
      explicit subtransaction block.
- [ ] 2.4 Vet modules and promote them to the tested list, each with a
      regression test inside PostgreSQL: gsl, mpfr, csv, xml, stldict,
      stllib, rational. Fix pure-glpk's error hook in the fork.
- [ ] 2.5 hegel property tests for the conversions: for generated values of
      each type, `identity(v) = v`, and every value out of range is an
      ERROR, never a wrong answer.
- [ ] 2.6 Benchmarks against PL/pgSQL, PL/Python and PL/Perl: interleaved
      runs and medians, method and box recorded under `bench/` with a date.

Gate: phase 1 gate, plus the module tests and the property suite.

## Phase 3: the trusted language and the remaining PL features

- [ ] 3.1 Design libpure's safe mode with the Pure maintainer before
      writing code (DESIGN.md section 9).
- [ ] 3.2 Implement safe mode in the fork, with escape tests: every route in
      section 9 must be refused.
- [ ] 3.3 `plpure` (trusted): curated prelude, one interpreter per SQL
      user, `trusted = true` extension.
- [ ] 3.4 Event triggers; transaction control in procedures (`sql::commit`,
      `sql::rollback`).

Gate: phase 2 gate plus the escape suite, and an independent security
review of the safe mode before any release that includes `plpure`.

## Phase 4: release

- [ ] 4.1 Docs (SGML and HTML), the PGXN package, Debian packaging, and
      RELEASING.md in the style of pg_fts's.

## Decided

- 2026-10-27: development and every build and test run on an EC2 Debian 13
  box in the kiwi account, never on floki (Greg).
- 2026-10-27: the languages are `pg_pure` (trusted, the ship target) and
  `pg_pureu` (untrusted, superuser only), following the PL/Perl
  `plperl`/`plperlu` model with `pg_` names. We keep both; we ultimately
  ship `pg_pure` (Greg).
- 2026-10-28: reuse pg_fts's PGXN/CI/release/announce machinery (META.json
  two-provides, `ci/announce.sh`, GitHub Actions). Repo home is GitHub
  (github.com/gburd/pg_pure), not Codeberg.
- 2026-10-28: support PG 17, 18 and 19 (19 via the PGDG snapshot repo until
  release). FreeBSD is a supported platform; Windows is not (DESIGN.md 10).
- 2026-10-27: a PostgreSQL built without LLVM (no `postgresql-NN-jit`) is a
  supported deployment and needs no libpure symbol fix; it gives up the
  server's own JIT. DESIGN.md section 5a. (Greg is also moving PostgreSQL to
  LLVM 21 in a separate effort, which removes the clash a different way.)
