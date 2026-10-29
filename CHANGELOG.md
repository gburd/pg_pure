# Changelog

All notable changes to pg_pure are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions are
[semantic](https://semver.org/).

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
