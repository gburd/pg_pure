# pg_pure roadmap

This is the only plan file. The design and its reasons are in `DESIGN.md`,
the working rules in `AGENTS.md`. Each phase ends with a gate. A phase is
done when its gate has run on the EC2 box and the output shows that every
test in it actually ran.

## Phase 0: libpure prerequisites (in github.com/gburd/pure-lang) -- DONE

Both landed in the fork on `libpure-embeddable` (tip `ab12de13`):

- [x] 0.1 libpure no longer exports its LLVM symbols, so it cannot clash with
      a host's `llvmjit` of a different LLVM major (commit "Hide libpure's
      LLVM symbols ..."). pg_pure links it unchanged; the "PostgreSQL without
      -jit" workaround is retired. Verified: 0 `llvm::` exports, libpure
      `make check` 95/95, both pg_pure suites pass with `jit=on,
      jit_above_cost=0` on PG 17/18/19, 0 crashes.
- [x] 0.3 A safe mode (commit "Add a safe mode ..."): `pure_is_safe`,
      `pure_safe_allow_using`, `pure_safe_arm`. This is what the trusted
      `pg_pure` uses (phase 3).
- [ ] 0.2 Keep a crash-matrix reproducer in pg_pure's TAP suite (ROADMAP 1.7)
      so a future libpure that re-exports LLVM is caught. (Not in the fork;
      it belongs here.)

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
      numeric via math, and **float8[] <-> Pure double matrix** (0.3: 1-D
      vectors and 2-D matrices both directions; NULL-element arrays and
      >2-D rejected; `using gsl::matrix` etc. work because the add-on Pure
      modules are now built and installed alongside libpure). Still to do:
      composites as records, other types through text I/O, a UTF-8
      conversion for other encodings.
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
- [ ] 1.4a Parameterized SPI -> now phase 2.C (see below).
- [ ] 1.5 Set-returning functions -> now phase 2.D; triggers and procedures
      remain in phase 2b.
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

## Phase 2: adoption blockers from the pg.ddx.io evaluation

Ordered by feasibility (easiest first). The pg.ddx.io team's 2026-10-29
evaluation listed these as "what would change the answer"; arrays (1.3) and
gsl (now built + a Cholesky PR to pure-gsl) are done, leaving these four.

- [ ] 2.A **Nix package for libpure + add-on modules.** Packaging only, no
      pg_pure code. A flake/derivation that builds libpure from the fork
      (LLVM 21, GMP/MPFR) and the vetted modules (gsl, ...), so a host like
      pg.ddx.io does not maintain a bespoke LLVM build. Easiest and
      self-contained. Feasibility: high.
- [ ] 2.B **TAP suite** (crash matrix JIT+Pure both orders reading the log;
      cancel / `pg_terminate_backend`; 8 concurrent backends; RSS flat over
      1M calls). Test harness only, no new runtime code; the crash-matrix
      and RSS scripts already exist in `_/`. This is also ROADMAP 1.7 and
      0.2. Feasibility: high, mechanical.
- [ ] 2.C **Parameterized SPI** `sql::query (q, p1, ...)` / `sql::exec`
      (send parameters as Datums via SPI_execute_with_args; never splice).
      Real C, but the Pure->Datum conversion already exists. Feasibility:
      medium.
- [ ] 2.D **Set-returning functions** (a Pure list or lazy stream into a
      tuplestore, forced element by element so an infinite stream is bounded
      by the row limit / cancel). Hardest: tuplestore + materialize mode +
      lazy forcing + per-row type conversion. Feasibility: medium-hard.

## Phase 2b: depth

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

- [x] 3.1/3.2 libpure safe mode designed and landed in the fork
      (`pure_is_safe`/`pure_safe_allow_using`/`pure_safe_arm`); see phase 0.
- [x] 3.3a `pg_pure` (trusted) runs each function in a `--safe`, armed
      interpreter: a body attempting `extern`, inline code, `eval`/`evalcmd`,
      a native or off-allowlist `using`, or a dangerous prelude function is
      refused as an SQL ERROR and the backend survives. `sql/pg_pure.sql`
      covers each route; passes on PG 17/18/19.
- [ ] 3.3b One interpreter per SQL user (DESIGN.md 9.4): today a single armed
      interpreter serves all `pg_pure` functions in a backend. Key it by
      `GetUserId()` so SECURITY DEFINER functions cannot share state.
- [ ] 3.3c A curated `--safe` prelude (DESIGN.md 9.5) instead of the denylist,
      designed with the Pure maintainer; independent security review before
      relying on the trusted language for untrusted multi-tenant use.
- [ ] 3.4 Event triggers; transaction control in procedures (`sql::commit`,
      `sql::rollback`).

Gate: phase 2 gate plus the escape suite (have it in `sql/pg_pure.sql`), and
an independent security review of the safe mode before relying on `pg_pure`
for untrusted multi-tenant workloads.

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
- 2026-10-29: libpure landed both fixes in the fork (`ab12de13`): LLVM
  symbols hidden (no coexistence workaround needed) and a safe mode. pg_pure
  0.2.0 wires the trusted `pg_pure` to the safe mode; both languages now run
  and pass on PG 17/18/19 with `jit=on`.
- 2026-10-30: pg_pure 0.3.0 adds `float8[]` <-> Pure double-matrix support
  (both languages) and the dev build installs the add-on Pure modules, so
  `using gsl::matrix` works. From the pg.ddx.io evaluation: arrays unblock
  writing their `commit_model_solve`, but a pure-Pure Cholesky over Pure
  lists is ~832 ms at K=18 vs ~23 ms PL/pgSQL -- not competitive. The unlock
  is a compiled binding: `gsl::linalg::cholesky_solve` (PR to the fork,
  gburd/pure-lang#1) runs K=18 in 0.02 ms. Remaining pg.ddx.io asks are
  phase 2.A-2.D, ordered by feasibility. Dev work now on the `chef` burner
  account (kiwi expired).
