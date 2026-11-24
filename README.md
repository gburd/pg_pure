# pg_pure — write PostgreSQL functions in Pure

[![CI](https://github.com/gburd/pg_pure/actions/workflows/ci.yml/badge.svg)](https://github.com/gburd/pg_pure/actions/workflows/ci.yml)
[![License: PostgreSQL](https://img.shields.io/badge/license-PostgreSQL-blue)](LICENSE)

pg_pure makes [Pure](https://agraef.github.io/pure-lang/) a procedural language
in PostgreSQL, the way PL/Perl and PL/Python do for their languages. A function
body is Pure code; it runs in a Pure interpreter (libpure) embedded in the
backend, and from there it can reach the database through SPI.

Pure is a functional language built on term rewriting: equational definitions
with pattern matching, exact rational and arbitrary-precision arithmetic, lazy
streams, and genuine symbolic computation. That last part is the reason to
reach for it in SQL. No other in-database language simplifies `x*1 + 0*y` to
`x`.

```sql
CREATE EXTENSION pg_pureu;

CREATE FUNCTION simplify(e text) RETURNS text LANGUAGE pg_pureu AS $$
  str (reduce (val e) with
         x*1 = x; 1*x = x; 0*x = 0; x*0 = 0; x+0 = x; 0+x = x
       end)
$$;

SELECT simplify('x*1 + 0*y + (x+0)');   -- x+x
```

## Two languages: pg_pure and pg_pureu

Like PL/Perl (`plperl`/`plperlu`) and PL/Tcl (`pltcl`/`pltclu`), pg_pure ships
a trusted and an untrusted variant from one shared library:

| Extension | Trust | Who can use it | Status |
|---|---|---|---|
| `pg_pure`  | trusted   | any user | works; runs in a libpure sandbox |
| `pg_pureu` | untrusted | superuser only | works |

A Pure program can normally call any C function through an `extern`
declaration, so untrusted Pure is as powerful as a C extension; only a
superuser may create `pg_pureu` functions. The trusted `pg_pure` runs each
function in a libpure **safe-mode** interpreter: a body that tries `extern`,
inline C, `eval`/`evalcmd`, a native or non-allowlisted `using`, or a
dangerous prelude function (`exit`, `malloc`, raw pointers) is refused as an
SQL ERROR, and the backend is unharmed. So an unprivileged user can write
`pg_pure` functions safely, the way PL/Perl's `plperl` is safe. See
`DESIGN.md` §9 for exactly what the sandbox blocks and what is still to come
(per-SQL-user interpreters, a curated prelude, a security review before
multi-tenant reliance).

## Examples

All of these run under either language; `pg_pure` (trusted) is usable by any
user. Every snippet here is exercised by the regression suite or was run on
the build host.

Arbitrary-precision arithmetic, because Pure integers promote to bigints:

```sql
CREATE FUNCTION factorial(n int) RETURNS numeric LANGUAGE pg_pureu AS $$
  foldl (*) 1L (1..n)
$$;
SELECT factorial(30);   -- 265252859812191058636308480000000
```

Exact rationals (the `math` module, loaded by default, gives `%`):

```sql
CREATE FUNCTION harmonic(n int) RETURNS numeric LANGUAGE pg_pureu AS $$
  using math;
  foldl (+) 0 [1%k | k = 1..n]
$$;
SELECT harmonic(10);    -- 7381/2520 as an exact numeric: 2.9289682539...
```

Recursion and pattern matching:

```sql
CREATE FUNCTION fib(n int) RETURNS numeric LANGUAGE pg_pureu AS $$
  loop n 0L 1L with loop 0 a _ = a; loop k a b = loop (k-1) b (a+b) end
$$;
SELECT fib(100);        -- 354224848179261915075
```

A set-returning function from a lazy stream (an infinite prime sieve, cut to n):

```sql
CREATE FUNCTION primes(n int) RETURNS SETOF int LANGUAGE pg_pureu AS $$
  take n (sieve (2..inf)) with
    sieve (p:qs) = p : sieve [q | q = qs; q mod p] &
  end
$$;
SELECT * FROM primes(10);   -- 2 3 5 7 11 13 17 19 23 29
```

The body must bound the stream itself (`take n ...`): a set-returning function
materializes its rows before `LIMIT` applies, so `SELECT * FROM primes(10)
LIMIT 4` still computes ten primes, and an unbounded body is stopped by cancel
or a row cap, not by `LIMIT`.

Numeric arrays: `float8[]` maps to a Pure double matrix, so vector and matrix
math works both directions. A 1-D array is a row vector, a 2-D array an n-by-m
matrix:

```sql
CREATE FUNCTION vscale(v float8[], k float8) RETURNS float8[]
  LANGUAGE pg_pure AS $$ map (*k) v $$;
SELECT vscale(ARRAY[1,2,3]::float8[], 10.0);      -- {10,20,30}

CREATE FUNCTION mtransp(m float8[]) RETURNS float8[]
  LANGUAGE pg_pure AS $$ using gsl::matrix; transpose m $$;
SELECT mtransp(ARRAY[[1,2,3],[4,5,6]]::float8[]);  -- {{1,4},{2,5},{3,6}}
```

For a dense linear solve, use the compiled routine, not a hand-written one: a
pure-Pure Cholesky is correct but slow, so prefer `gsl::linalg::cholesky_solve`
(in pure-gsl as of the module version pg_pure 0.4.0 builds against). It solves
a symmetric positive-definite `A x = b` over `float8[]` at C speed:

```sql
-- the DBA allow-lists the module once: pg_pure.using = 'math gsl::linalg'
CREATE FUNCTION solve_spd(a float8[], b float8[]) RETURNS float8[]
  LANGUAGE pg_pure AS $$ gsl::linalg::cholesky_solve a b $$;
```

That calls GSL's compiled routine, so once the backend is warm it runs about
4x faster than a hand-written PL/pgSQL Cholesky (1.6 vs 6.0 us per call on a
c7i.4xlarge; see `bench/`).  The first call in a fresh backend pays a one-time
LLVM compile of about 9 seconds, so the win applies to long-lived connections
that call the function many times, not one-shot connections.  See Performance
below and `bench/README.md` for the full method and numbers.

Reaching the database with SPI, with a parameter passed as data (never
spliced), and catching a SQL error by its SQLSTATE:

```sql
CREATE FUNCTION add_user(email text) RETURNS bool LANGUAGE pg_pureu AS $$
  catch dup (sql::exec ("INSERT INTO users(email) VALUES ($1)", [email]) > 0)
  with dup (sql::error "23505" _) = false; dup e = throw e end
$$;
```

Parameters go to the planner as Datums via `SPI_execute_with_args`: the call
shape is `sql::query (q, [p1, p2, ...])` and `sql::exec (q, [...])`, and a
parameter's SQL type is inferred from the Pure value (int, double, string,
bigint, or `sql::null`). The no-parameter forms `sql::query q` and
`sql::exec q` still work.

Triggers. A `RETURNS trigger` function sees `new` and `old` (row records, or
`sql::null` when the event has none) and `tg` (a record describing the event,
with keys like "op", "when", "level" and "table_name"). A BEFORE-row body
returns a record to become the stored row, overriding only the columns it
names, or `sql::null` to skip the row:

```sql
CREATE FUNCTION fill_total() RETURNS trigger LANGUAGE pg_pureu AS $PURE$
  insert new ("total" => new!"qty" * new!"price")
$PURE$;
CREATE TRIGGER t_total BEFORE INSERT OR UPDATE ON line_item
  FOR EACH ROW EXECUTE FUNCTION fill_total();
```

The body overrides only `total`; the other columns keep the values the
statement supplied. Returning `sql::null` from a BEFORE-row trigger skips the
operation. AFTER and statement triggers ignore the return value.

## Requirements

- PostgreSQL **17, 18, or 19**. All three build and pass the regression suite,
  gated in CI against the released PGDG packages.
- **libpure**, built from the fork below. It is not packaged; you build it once.
- A C toolchain and the server headers (`postgresql-server-dev-NN`).

### Building libpure (once)

pg_pure embeds libpure from a fork that makes the runtime safe to embed in a
host process (it does not call `exit()`, returns exceptions to the host, and
offers hooks for query-cancel and the stack limit). Build and install it from:

```sh
git clone --branch libpure-embeddable https://github.com/gburd/pure-lang.git
cd pure-lang/pure
autoreconf -fi
./configure --prefix=$HOME/pure --with-tool-prefix=$(llvm-config --bindir) --enable-release
make -j
make install          # installs libpure.so + headers + the prelude under $HOME/pure
```

libpure needs LLVM (20.1+; tested with 21) and GMP/MPFR/readline. On Debian:
`apt install llvm-21-dev clang-21 libgmp-dev libmpfr-dev libreadline-dev`.

### PostgreSQL JIT coexistence

libpure JIT-compiles Pure with LLVM, and so does PostgreSQL's own JIT
(`llvmjit`), often a different LLVM major. The fork's libpure hides its LLVM
symbols so the two cannot clash, so **nothing special is required**: pg_pure
runs on a normal `jit = on` server. (This is tested in CI with
`jit_above_cost = 0`, which forces a JIT-compiled query into the same backend
as a Pure function, on PostgreSQL 17/18/19 with zero crashes.) `DESIGN.md` §5
has the history and the one guard the test suite keeps against a future
libpure that regresses it.

## Build and install pg_pure

```sh
make PG_CONFIG=/path/to/pg_config PURE_PREFIX=$HOME/pure
sudo make install PG_CONFIG=/path/to/pg_config PURE_PREFIX=$HOME/pure
```

`PURE_PREFIX` is where you installed libpure above. The prelude is found through
libpure's built-in path; if the server runs with a non-standard install, set
`PURELIB` in the server's environment to the directory holding `prelude.pure`.

Then, in a database, as a superuser:

```sql
CREATE EXTENSION pg_pureu;
```

For low per-call latency, preload the interpreter in the postmaster so backends
inherit it (otherwise the first call in each new backend pays a one-time cost,
see Performance):

```
# postgresql.conf
shared_preload_libraries = 'pg_pure'
pg_pure.using = 'math'      # modules every interpreter loads; default: math
```

## Pure behaviour that surprises SQL users

These are real rough edges, not bugs. Each is something a SQL author hits and
needs to understand.

- **An unmatched application is not an error — it is a normal form.** If your
  rules do not match the argument, Pure leaves the expression unevaluated
  (`f 2` stays `f 2`) rather than failing. pg_pure cannot convert that to the
  return type, so you get:
  ```
  ERROR:  pg_pureu: result f 2 cannot be converted to integer
  HINT:   Check the argument types your rules expect; an unmatched application
          stays unevaluated in Pure.
  ```
  The fix is almost always a catch-all rule (`f _ = ...`) or matching the
  right type.

- **SQL `int`/`smallint` are Pure machine integers, and they wrap silently.**
  `2147483647 + 1` is `-2147483648` inside Pure, as the Pure manual documents.
  The final result is range-checked when it is converted back (an out-of-range
  `smallint` is an error, not a wrong number), but a wrap *inside* the
  computation is not caught. If you need big intermediate values, work in
  `int8`/`numeric` (Pure bigints) or convert: `bigint x`.

- **SQL `bigint` arrives as a Pure bigint, and `0L` does not match the pattern
  `0`.** A rule `f 0 = ...` will not fire for an `int8` argument, and
  `take 5L xs` does not reduce (`take` wants a machine int). For `int8`
  arguments compare with `==`, or convert with `int n` when you know the value
  fits.

- **`numeric` is exact in and out.** An integral numeric is a Pure bigint; a
  fractional one is an exact rational (needs `math`, loaded by default). A
  non-terminating rational like `1%3` returned as `numeric` is rounded to the
  display scale, as any numeric division is. To return a rational as a float,
  convert in Pure: `double (1%3)`.

- **A `text` result must be a Pure string.** pg_pure will not stringify an
  arbitrary Pure value for you (that would hide the unmatched-application error
  above as plausible-but-wrong text). Call `str` yourself if you mean to.

- **Exceptions.** An uncaught Pure `throw` becomes
  `ERROR: pg_pureu: uncaught exception: <value>` (SQLSTATE 38000) and the
  session keeps working. A SQL error raised inside `sql::exec`/`sql::query`
  reaches Pure as `sql::error "SQLSTATE" "message"`; catch it to continue the
  transaction, or let it propagate to re-raise the original SQL error intact.

- **Runaway recursion is caught.** Pure stack overflow becomes the exception
  `stack_fault` (bounded by `max_stack_depth`), then a SQL error — not a crash.

- **`using` goes at the top of the body.** Module loads must precede the
  expression: `using gsl; gsl::stats::sd (matrix xs)`, not inline.

- **Global definitions made with `eval` are not transactional.** They survive
  a ROLLBACK. Ordinary function bodies have no such effect; a stray `;` in a
  body is a compile error, not a global leak.

- **A `statement_timeout` or `pg_terminate_backend` cancels a running Pure
  computation**, including an infinite loop, through libpure's interrupt hook.

## Performance

Measured on an EC2 c7i.4xlarge, Debian 13, PostgreSQL 17/18/19, libpure on
LLVM 21, 2026-11-24.  The harness and the full results are in `bench/`.

pg_pure's cost is bimodal, and both halves matter.

**Cold first call is expensive.**  The first call to a given pg_pure function
in a backend compiles it with LLVM, about 9 s on this box.  PL/pgSQL,
PL/Python and PL/Perl each start a function in under 15 ms.  Preload
(`shared_preload_libraries`) warms the postmaster, but a forked backend does
not inherit the warmed codegen (the warmed JIT state does not survive fork,
ROADMAP 1.6), so every new connection pays this once per distinct function.
A connection pooler that keeps backends alive is the practical answer; without
one, pg_pure suits long-lived connections that call a function many times, not
one-shot connections.

**Warm steady state is a mixed result** (microseconds per call):

| workload | pg_pure | PL/pgSQL | PL/Python | PL/Perl |
|----------|--------:|---------:|----------:|--------:|
| fib  (iterative Fibonacci) |   9.7 |  4.1 |  1.8 |  2.8 |
| hsum (sum of i*i as numeric) |  97.8 | 17.6 |  4.5 |  3.2 |
| chol (3x3 SPD solve, float8[]) |   1.6 |  6.0 |   -  |   -  |

pg_pure is 2x to 5x slower on scalar recursion and much slower on exact-number
work (its integers are GMP rationals converted to `numeric`).  Where the body
calls a compiled routine, as `chol` does through `gsl::linalg::cholesky_solve`,
it beats a hand-written PL/pgSQL solve by about 4x because GSL's compiled C
does the work and Pure is only the glue.  The draw of pg_pure is
expressiveness and reaching compiled numerical libraries, not raw per-call
throughput.

## Status

0.11, in development. Working: both languages (`pg_pure` trusted via libpure
safe mode, `pg_pureu` untrusted), scalar functions over int2/int4/int8/
float4/float8/numeric/bool/text, exact numeric, NULL as `sql::null`,
`float8[]` <-> Pure double matrix, `bytea` <-> Pure byte matrix, domains (as
their base type, with the CHECK enforced), `sql::query`/`sql::exec` (with
parameters passed as Datums and a transparent plan cache), `sql::stream` (a
lazy cursor-backed result), set-returning functions (`RETURNS SETOF` of a
scalar or array, from a Pure list or a body-bounded lazy stream),
`sql::notice`/`sql::warning`, SQL-error-as-`sql::error`, DO blocks, DML
triggers (BEFORE/AFTER, ROW/STATEMENT, on INSERT/UPDATE/DELETE and TRUNCATE;
the body sees `new`, `old` and `tg`), the
validator, preload warm-up, the vetted add-on Pure modules (`gsl`,
`gsl::linalg`, `mpfr`, `dict`, `rational`), and a compiled
`gsl::linalg::cholesky_solve` SPD solve. A Nix package builds libpure
and the modules; a TAP suite covers the JIT+Pure crash matrix, cancel,
concurrency and bounded memory. PostgreSQL 17/18/19 pass both regression
suites with `jit=on` and zero crashes.

Not yet: `RETURNS TABLE` / SETOF composite, event triggers, composite types,
per-SQL-user trusted interpreters, and a curated safe-mode prelude. See
`ROADMAP.md`.

## Documentation

- The HTML reference manual: https://gburd.github.io/pg_pure/ (built from
  `doc/pg_pure.sgml`).
- `DESIGN.md` — the full design, the measurements, and the LLVM coexistence
  analysis.
- `ROADMAP.md` — the phased plan and what is done.
- `bench/` - the benchmark harness, method and measured results.

## License

PostgreSQL license (see `LICENSE`). pg_pure links libpure (LGPL-3)
dynamically. Pure library modules you load (`gsl`, `glpk` are GPL; `mpfr`,
`csv`, `stllib` are LGPL/MIT) are loaded by you at runtime, not shipped with
pg_pure. This is not legal advice.
