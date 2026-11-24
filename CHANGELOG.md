# Changelog

All notable changes to pg_pure are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions are
[semantic](https://semver.org/).

## [0.12.0] - 2026-11-24

### Fixed
- A use-after-free in the result-conversion error path.  When a function
  result did not fit its declared type, the value string was copied into the
  SPI memory context and then read after `SPI_finish` had destroyed that
  context to build the error message.  A normal build happened to still print
  the old bytes; a cassert build (which clobbers freed memory) showed the
  value as blank.  The string is now copied after `SPI_finish`, into the
  restored caller context.  Found by the new cassert build (ROADMAP 1.8).

### Added
- **Benchmark harness** (`bench/`): `setup.sql` defines the same three
  workloads (iterative Fibonacci, a numeric sum, a 3x3 SPD solve over float8[])
  in pg_pure, PL/pgSQL, PL/Python and PL/Perl; `run.sh` times them with warm
  steady-state and cold first-call measurements, interleaved, median of seven
  runs, server executor time.  `bench/README.md` records the method and the
  findings; `bench/results-2026-11-24.txt` is a captured run on PostgreSQL 17,
  18 and 19.
- **Formal documentation**: a DocBook reference manual (`doc/pg_pure.sgml`)
  rendered to HTML by `doc/build-html.sh` (xsltproc + docbook-xsl), published
  to GitHub Pages by a new Docs workflow.  `make html` builds it locally.
- **RELEASING.md** documents the tag-triggered release, the gate on 17/18/19,
  the Codeberg to GitHub mirror, and the PGXN publish.
- A trigger regression case in `sql/pg_pureu.sql` (the TAP suite already
  covered triggers; this adds coverage to the installcheck suite).

### Retracted
- The claim that `gsl::linalg::cholesky_solve` runs "about 40x faster than the
  same solve in PL/pgSQL" was wrong.  That figure came from a single warmed
  call measured in one session and ignored both the cold compile and a fair
  per-call comparison.  Measured properly (`bench/`, c7i.4xlarge, PostgreSQL
  17/18/19): warm, the compiled Cholesky is about 4x faster than a hand-written
  PL/pgSQL solve (1.6 vs 6.0 us per call), not 40x.  And pg_pure is not a
  general speed win: it is 2x to 5x slower warm on scalar recursion and much
  slower on exact-number loops, and every new backend pays a one-time LLVM
  compile of about 9 seconds per distinct function (the warmed JIT state does
  not survive fork; a connection pooler is the practical answer).  The README,
  `doc/pg_pure.sgml` and the ROADMAP now state the measured numbers.

## [0.11.0] - 2026-11-23

### Added
- **DML triggers.** A `RETURNS trigger` function can now back a trigger:
  BEFORE or AFTER, ROW or STATEMENT, on INSERT, UPDATE or DELETE (and
  TRUNCATE). The body sees three variables: `new` and `old` (the row
  records, or `sql::null` when the event has no such row) and `tg` (a record
  describing the event, with the keys "name", "when", "level", "op",
  "table_name", "table_schema" and "args"). For INSERT, `new` is the row and
  `old` is `sql::null`; for DELETE, `old` is the row and `new` is `sql::null`;
  for UPDATE, `new` is the new row and `old` the pre-update row.
- A BEFORE-row trigger body returns a record to become the stored row, or
  `sql::null` to skip the operation (PostgreSQL's own convention). A returned
  record overrides only the columns it names; columns it omits keep the row's
  original value, as PL/Python does, so a body need not echo every column.
  AFTER and statement triggers ignore the return value.
- `t/007_triggers.pl`: 12 tests covering each timing and operation, the
  skip-via-`sql::null` path, `tg`, and the error paths (a non-record return,
  an unknown column, and the single-expression escape guard), each asserting
  the backend survives. Passes on PostgreSQL 17, 18 and 19 with zero crashes.

### Notes
- The trigger wrapper builds `new`, `old` and `tg` through C externs it calls
  during evaluation, because libpure's compound-value constructors
  (`pure_app`, lists, tuples, records) require an active evaluation frame;
  building them in C before the call aborts the backend. Event triggers and
  procedure transaction control remain unsupported.

## [0.10.0] - 2026-11-23

### Added
- **`sql::stream`** -- a lazy, cursor-backed result. `sql::stream q` and
  `sql::stream (q, [params])` return a Pure list that fetches rows from an
  SPI cursor in batches as the list is consumed, so a body can process or
  reduce a large result without materializing all of it. The value is an
  ordinary lazy Pure list, so every list operation works: `foldl (+) 0
  (sql::stream "...")`, `take 3 (sql::stream "...")`, a comprehension, or a
  `head:tail` match.
- A stream is valid only within the function call that opened it. When the
  call returns, pg_pure closes the cursor; a stream value forced after that
  (for example one a body tried to hand back) raises a `sql::error`, and the
  backend survives -- it never touches the dropped cursor. Each force finds
  the cursor fresh by name and checks a per-call epoch, so there is no stored
  pointer to dangle.

### Notes
- Streaming a result to a *later* SQL statement (a holdable cursor that
  outlives the function call) is deferred; 0.10.0 streams are call-scoped.

## [0.9.0] - 2026-11-20

### Added
- **A plan cache for `sql::query` / `sql::exec`.** A parameterized query
  repeated with the same text and the same parameter types -- the common
  case of a query in a loop, or the same function called many times -- is now
  planned once and the saved plan is reused, instead of re-planning every
  call. The cache is transparent: no API change, no new Pure syntax. The
  cache key is the query text plus the inferred parameter type Oids, so the
  same text used with an int parameter and with a double parameter gets its
  own correct plan. PostgreSQL's plan cache revalidates a saved plan on its
  own when a referenced object, the search path, or the current role changes,
  so a cached plan never returns a stale answer. The cache holds up to 128
  plans per backend and evicts the least recently used.

## [0.8.0] - 2026-11-19

### Added
- **More vetted Pure modules**, built and installed alongside libpure and
  exercised by the regression suite: `mpfr` (arbitrary-precision floats --
  `mpfr_set_default_prec` then compute, e.g. pi to hundreds of bits),
  `dict` (the stldict STL-backed associative maps), and `rational`
  (utilities on math's exact rationals, such as a double to a fraction).
  These join `gsl`/`gsl::linalg` on the tested list. A body loads one with
  `using mpfr;` (etc.) in the untrusted language, or the DBA allow-lists it
  through `pg_pure.using` for the trusted language.

### Notes
- `csv`, `xml`, `stllib` and `glpk` build against the fork but are not yet on
  the tested list: csv and xml are file/document oriented and do not map
  cleanly to a single-expression function body, and glpk needs an ODBC
  library and a fork-side fix to its error hook. They may be promoted later.

## [0.7.1] - 2026-11-19

### Changed
- PostgreSQL 19 reached general availability. CI and the release build now
  install it from the released PGDG repository instead of the snapshot
  repository. The extension is unchanged; it builds and passes the regression
  and TAP suites on PostgreSQL 17.12, 18.7 and 19.0, with `jit=on` and zero
  crashes (libpure's hidden LLVM symbols coexist with the released PG 19
  llvmjit).

## [0.7.0] - 2026-11-18

### Added
- **bytea.** A `bytea` argument maps to a Pure int matrix (a 1-by-n row of
  byte values 0..255), and a function returning `bytea` yields one. Because
  the bytes live in a matrix, not a string, arbitrary binary -- including
  embedded NUL -- round-trips, and a body can read the bytes (`list x`) or
  build them (`{65,66,67}`). A matrix element outside 0..255 is an error, not
  a silent wrap.
- **Domains.** A domain-typed argument or return value is accepted as its
  base type. The domain's CHECK constraints are enforced: PostgreSQL checks
  the argument, and pg_pure checks the function's result (`CREATE DOMAIN
  posint AS int4 CHECK (VALUE > 0)` rejects a function that returns a
  non-positive value).

## [0.6.2] - 2026-11-18

### Fixed
- **A trusted function body could escape its wrapping and define a top-level
  Pure rule**, leaking interpreter state to another function in the same
  backend. A body is compiled as `name args = (body);`, and a crafted body
  (for example `0); leaked = 999; (0`) could close the parenthesis and add a
  global definition that a later function in the same session would see. The
  body is now required to be a single expression: it is rejected at
  definition time if it closes a bracket it did not open or leaves one open
  (counting brackets while skipping strings and comments). Legitimate bodies,
  including `with`/`when` blocks and text containing brackets, are unaffected.
  The same check applies to DO blocks. libpure's safe mode does not block
  top-level definitions (it blocks the routes out of the language: extern,
  inline code, eval, and native or off-allowlist using), so this guard is
  what keeps one trusted function's interpreter state private from the next.

## [0.6.1] - 2026-11-18

### Fixed
- **numeric round-trip lost precision.** A `numeric` value with a fractional
  part could come back changed: `123.456` returned `123.46`, and
  `0.333` returned `0.219`. Two causes, both in the numeric conversion.
  Passing a value in, the fractional mantissa kept its leading zeros
  (`0.333` built the Pure literal `0333`, which Pure reads as octal `219`);
  a mantissa with an `8` or `9` digit (`0.123456789012345`) was invalid octal
  and raised a spurious "cannot represent numeric value" error. Returning a
  value, the result scale was derived from the rational's denominator
  assuming it was a power of ten, but the math module returns the rational in
  lowest terms (`123.456` as `15432/125`), so the value was rounded to too
  few digits. A negative value (`-0.25`) and a large-magnitude value
  (`1234567890.123456789`) were also mishandled. All `numeric` values now
  round-trip exactly; a non-terminating rational is rounded to a display
  scale, as numeric division always is.

### Added
- **Property round-trip tests for the type conversions** (`t/003_conversions.pl`):
  across each supported type (int2/4/8, float4/8, numeric, bool, text,
  `float8[]`), generated values round-trip through a pg_pure identity
  function exactly, and a value that does not fit its type is an error, never
  a silent wrap or truncation. This is the test that found the numeric bug
  above.
- **A preload behaviour test** (`t/004_preload.pl`): a server with
  `shared_preload_libraries = 'pg_pure'` starts, warms, and serves Pure from
  forked backends without a crash. It records the first-call latency with and
  without preload. Note: preload currently front-loads the one-time codegen
  into postmaster startup but does not lower a forked backend's first-call
  latency; the warmed interpreter state is not effectively inherited across
  fork. A connection pooler, which keeps backends warm, is the way to avoid
  the cost today.

## [0.6.0] - 2026-11-09

### Added
- **Set-returning functions.** A function declared `RETURNS SETOF <type>`
  whose body yields a Pure list produces one row per element:
  `CREATE FUNCTION range(lo int, hi int) RETURNS SETOF int LANGUAGE pg_pure
  AS 'lo..hi'`. The element type may be any supported scalar or `float8[]`.
  Rows are collected into a tuplestore (materialize mode), and each element
  is converted with the same range checks as a scalar result. Works in the
  trusted language too.
- A **lazy or infinite Pure stream** is walked one cons cell at a time, so a
  stream the body itself bounds (e.g. `take n (iterate (+1) 1)`) returns its
  rows without realizing the rest. A `CHECK_FOR_INTERRUPTS` between rows means
  `statement_timeout` / cancel always stops a long stream and the backend
  survives (covered by the TAP suite).

### Notes
- A set-returning function materializes all its rows before the executor
  applies `LIMIT`, so `LIMIT` does not bound an unbounded body -- bound the
  stream in the body (`take n ...`). An unbounded body is stopped by cancel,
  and a hard row cap turns a runaway stream into an error rather than an
  out-of-memory.
- `RETURNS TABLE(...)` and `SETOF` of a composite type are not yet supported
  (they need multi-column tuple construction); a clear error says so.

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
