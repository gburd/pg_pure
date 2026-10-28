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
| `pg_pure`  | trusted   | any user | **stub for now**: the handler refuses to run until libpure has a sandbox (see below) |
| `pg_pureu` | untrusted | superuser only | works today |

A Pure program can call any C function through an `extern` declaration, so
untrusted Pure is as powerful as a C extension and only a superuser may create
`pg_pureu` functions. The trusted `pg_pure` needs a sandboxed libpure that
refuses `extern`, inline C, `eval`, and arbitrary `using`; that sandbox does
not exist yet, so `pg_pure` functions currently raise:

```
ERROR:  pg_pure (trusted) is not available in this version
HINT:   Use pg_pureu as a superuser, or wait for the sandboxed pg_pure.
```

The `pg_pure` extension is installable now so its catalog entry and grants are
in place; when the sandbox lands, the same functions start working with no
migration. See `DESIGN.md` §9.

## Examples

All of these run under `pg_pureu`. Every snippet here is exercised by the
regression suite or was run on the build host.

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
*(Set-returning functions are on the roadmap, not in 0.1; see Status.)*

Reaching the database with SPI, catching a SQL error by its SQLSTATE:

```sql
CREATE FUNCTION add_user(email text) RETURNS bool LANGUAGE pg_pureu AS $$
  catch dup (sql::exec ("INSERT INTO users(email) VALUES ($1)", email) > 0)
  with dup (sql::error "23505" _) = false; dup e = throw e end
$$;
```
*(Parameterized `sql::query`/`sql::exec` are on the roadmap; 0.1 builds the SQL
string in Pure.)*

## Requirements

- PostgreSQL **17, 18, or 19**. All three build and pass the regression suite
  (gated in CI; 19 against the PGDG snapshot until it is released).
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

### The LLVM coexistence rule (read this before enabling JIT)

libpure JIT-compiles Pure with LLVM, and so does PostgreSQL's own JIT
(`llvmjit`). If the two link **different** LLVM major versions and both end up
in one backend, the backend crashes at exit (one backend crash restarts every
session). Three deployments avoid it:

1. **A PostgreSQL built without LLVM.** On Debian, `llvmjit` is the separate
   package `postgresql-NN-jit`; without it installed, no backend loads LLVM and
   `jit = on` is a silent no-op. pg_pure then works with any libpure build.
   **This is the supported path for 0.1** and is what CI tests.
2. **A PostgreSQL whose `llvmjit` matches libpure's LLVM major.** One copy, no
   clash.
3. **A libpure built so it exports no LLVM symbols** (link with `-Bsymbolic`
   and a version script). This lets a stock PGDG server (LLVM 19) and an
   LLVM-21 libpure coexist. It is a libpure change tracked as a fork PR; until
   it lands, use deployment 1 or 2 on a JIT-enabled server.

`DESIGN.md` §5 and §5a have the evidence and the crash backtrace.

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

Measured on an EC2 c7i.4xlarge, Debian 13, PG 18, libpure on LLVM 21:

| | |
|---|---|
| First `pg_pureu` call in a fresh backend (no preload) | ~5.3 s (interpreter create + LLVM codegen of the prelude) |
| First call, preloaded and warmed in the postmaster | ~0.16 s |
| Each further new function's first call | 72–165 ms |
| 1M calls of `x*y+1` in one SELECT | plain SQL ~97 ms, PL/pgSQL ~306 ms, pg_pureu ~455 ms |
| Backend memory after the first call | ~105 MB private |

The one-time first-call cost is LLVM compiling the Pure prelude code the call
reaches. **Preload** (`shared_preload_libraries`) pays it once in the
postmaster; backends then inherit it by fork. A connection pooler helps either
way, since the interpreter is per-backend.

## Status

0.1, in development. Working: scalar functions over int2/int4/int8/float4/
float8/numeric/bool/text, exact numeric, NULL as `sql::null`, `sql::query`/
`sql::exec`/`sql::notice`/`sql::warning`, SQL-error-as-`sql::error`, DO blocks,
the validator, preload warm-up, and `pg_pure` as an installable stub. All of PG
17/18/19 pass the regression suite with zero crashes.

Not yet: parameterized SPI, set-returning functions, triggers, arrays and
composites, the trusted sandbox, and the TAP suite. See `ROADMAP.md`.

## Documentation

- `DESIGN.md` — the full design, the measurements, and the LLVM coexistence
  analysis.
- `ROADMAP.md` — the phased plan and what is done.

## License

PostgreSQL license (see `LICENSE`). pg_pure links libpure (LGPL-3)
dynamically. Pure library modules you load (`gsl`, `glpk` are GPL; `mpfr`,
`csv`, `stllib` are LGPL/MIT) are loaded by you at runtime, not shipped with
pg_pure. This is not legal advice.
