# Changelog

All notable changes to pg_pure are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions are
[semantic](https://semver.org/).

## [0.5.0] - 2026-11-09

### Added
- **Parameterized SPI.** `sql::query` and `sql::exec` now take an optional
  parameter list: `sql::query (q, [p1, p2, ...])` and
  `sql::exec (q, [...])`. The values are passed to the planner as Datums via
  `SPI_execute_with_args` -- never spliced into the SQL text -- so a value
  full of SQL metacharacters is just data, not an injection. The SQL type is
  inferred from each Pure value (int -> int8, double -> float8, string ->
  text, bigint -> numeric, `sql::null` -> a SQL NULL); anything else is a
  clear type error. Works in the trusted language's armed interpreter too.
  The no-parameter forms (`sql::query q`, `sql::exec q`) are unchanged.
- **A Nix package** (`nix/flake.nix`) that builds libpure from the fork
  (LLVM 21, GMP/MPFR) and the pure-gsl modules, exposing `libpure`,
  `pure-gsl`, `pure-with-modules` and a devShell. A host can point
  `PURE_PREFIX` at the result instead of maintaining a bespoke LLVM build.
  `nix flake check` passes. See `nix/README.md`.
- **A TAP suite** (`t/001_crash_matrix.pl`, `t/002_robustness.pl`): the
  PostgreSQL-JIT-and-Pure crash matrix in both orders (read from the server
  log, on a JIT-enabled PostgreSQL 17/18/19, 0 crashes); cancel via
  `statement_timeout` and `pg_terminate_backend`; eight concurrent backends;
  and a backend's resident memory plateauing over millions of calls (the
  fourth 1,000,000-call batch adds about 0 MB, so there is no per-call leak).
  `ci/gate.sh` runs the regression and TAP suites together; CI runs the TAP
  suite as its own step.

### Notes
- This release adds no new type conversions and no change to the trust model;
  it is additive. It closes three of the four remaining items from the
  pg.ddx.io evaluation (parameterized SPI, the qualification TAP suite, and
  the libpure Nix package). Set-returning functions remain for a later,
  focused release.

## [0.4.0] - 2026-11-02

### Added
- A compiled linear solve: `gsl::linalg::cholesky_solve` is now usable from
  pg_pure, having landed in the pure-gsl module (fork `gburd/pure-lang`, PR
  #1). A function can solve a symmetric positive-definite system `A x = b`
  over `float8[]` at C speed -- about 40x faster than the same solve written
  in PL/pgSQL, and far faster than a solve written in pure Pure over Pure
  lists (which is not competitive). `sql/pg_pure.sql` adds a
  `gsl::linalg::cholesky_solve`-backed solver and checks it agrees with the
  pure-Pure Cholesky to 12 decimals.

### Notes
- In the trusted `pg_pure` language, a module like `gsl::linalg` must be
  pre-loaded and allow-listed by the DBA through `pg_pure.using` (e.g.
  `pg_pure.using = 'math gsl::linalg'`); a trusted function body may then call
  `gsl::linalg::cholesky_solve` directly. A trusted body may **not** pull in
  an arbitrary module with its own `using` clause -- that is the DBA's
  decision, and libpure's safe mode enforces it. (`pg_pureu`, untrusted, may
  `using` any installed module.)
- Known libpure refinement: in safe mode, a body's `using gsl::linalg` is
  rejected by the module-path check before the allowlist is consulted, so the
  pre-load-via-GUC path above is the supported way to use a namespaced
  submodule in the trusted language.

## [0.3.0] - 2026-10-30

### Added
- **`float8[]` arrays map to and from Pure double matrices**, in both
  languages. A 1-D `float8[]` becomes a 1-by-n Pure matrix (row vector); a
  2-D `float8[][]` becomes an n-by-m matrix; the same shapes convert back on
  return. A function can now take and return `float8[]`, so numeric kernels
  (a Cholesky SPD solve, vector/matrix ops) run in Pure. Arrays containing
  SQL NULL, and arrays with more than two dimensions, are rejected with a
  clear error (a Pure double matrix is a dense rectangle of doubles).
- The development build now installs the add-on Pure modules alongside
  libpure, so `using gsl`, `using gsl::matrix`, etc. work in a function body
  (untrusted) or when allow-listed via `pg_pure.using` (trusted).

### Notes
- A Cholesky/SPD solve written in pure Pure (over Pure lists) is correct but
  not fast (~832 ms at K=18 vs ~23 ms in PL/pgSQL): Pure lists give O(n)
  index/append. For a competitive solve use a compiled routine; a
  `gsl::linalg::cholesky_solve` binding (proposed to pure-gsl,
  gburd/pure-lang#1) runs K=18 in 0.02 ms.

## [0.2.0] - 2026-10-29

### Added
- **The trusted language `pg_pure` now runs.** It executes each function in a
  libpure safe-mode interpreter (`--safe`, armed after the SPI bridge and the
  `pg_pure.using` modules are set up), so any user may create `pg_pure`
  functions. A body that attempts `extern`, inline C, `eval`/`evalcmd`, a
  native or non-allowlisted `using`, or a dangerous prelude function (`exit`,
  `malloc`, raw pointers) is refused as an SQL ERROR and the backend
  survives. `sql/pg_pure.sql` exercises each route. Previously `pg_pure`
  refused to run and only `pg_pureu` worked.
- Trusted and untrusted each get their own backend-local interpreter; the
  function cache keys on the interpreter so the two never collide.

### Changed
- Requires libpure from the fork at `libpure-embeddable` >= `ab12de13` (it
  provides the safe-mode API and hides its LLVM symbols).
- Dropped the "install PostgreSQL without its `-jit` package" guidance: the
  fork's libpure no longer exports LLVM symbols, so pg_pure runs on a normal
  `jit = on` server. Both suites pass with `jit_above_cost = 0` on
  PostgreSQL 17/18/19 with zero backend crashes.

## [0.1.1] - 2026-10-28

### Fixed
- META.json carried an invalid PGXN tag (`pl/pure`; `/` is not allowed by the
  PGXN Meta Spec), which PGXN rejected, so **0.1.0 never published to PGXN**.
  The tag is now `plpure`. The extension code is identical to the 0.1.0 tree;
  this is a metadata-only fix so the distribution can be released.
- The release workflow treated a PGXN `409` as "already published" and skipped,
  which masked the rejected 0.1.0 upload as a success. It now distinguishes an
  already-published 409 from a real rejection by the response body, and
  verifies the release is indexed on api.pgxn.org before reporting success.

## [0.1.0] - 2026-10-28 (not published to PGXN)

### Added
- Initial extension. One shared library (`pg_pure.so`) backs two SQL
  languages: `pg_pure` (trusted) and `pg_pureu` (untrusted, superuser-only),
  following the PL/Perl `plperl`/`plperlu` model.
- Scalar functions in Pure over int2, int4, int8, float4, float8, numeric,
  bool, text and varchar, with exact numeric (bigint and rational) in and out
  and range-checked conversions.
- SQL NULL as the Pure symbol `sql::null`.
- Database access from Pure: `sql::query`, `sql::exec`, `sql::notice`,
  `sql::warning`. A SQL error raised in a query reaches Pure as
  `sql::error "SQLSTATE" "message"` (each query runs in an internal
  subtransaction), so Pure code can catch it by SQLSTATE and continue the
  transaction, or let it propagate to re-raise the original error.
- DO blocks (`DO LANGUAGE pg_pureu`).
- The validator compiles a function at CREATE time.
- Leading `using MODULE;` lines in a body load Pure modules.
- Cooperative cancel (`statement_timeout`, `pg_terminate_backend`) and stack
  overflow (`stack_fault`) via libpure's host hooks: neither crashes the
  backend.
- Optional preload (`shared_preload_libraries = 'pg_pure'`) builds and warms
  the interpreter in the postmaster so backends inherit it by fork; the
  `pg_pure.using` GUC lists the modules to load (default `math`).
- `pg_pure` (trusted) is installable but its handler refuses to run until
  libpure gains a sandbox (DESIGN.md section 9).
- Regression suite passes on PostgreSQL 17, 18 and 19 with zero backend
  crashes.
