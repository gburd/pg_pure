# pg_pure design

Status: draft for review, 2026-10-27. Nothing here is built yet. The only
code is the prototype in `_/plpure` (600 lines of C, see
`pg_pure-notes.md`). Every number below was measured on an EC2 c7i.4xlarge
running Debian 13 (AMI debian-13-amd64-20261026-2643), PostgreSQL 17.11 and
18.6 from PGDG, LLVM 21.1.8, libpure from github.com/gburd/pure-lang branch
`libpure-embeddable` at a433e813. Most runs were repeated two or three
times. No variance analysis was done.

## 1. What this is

pg_pure makes Pure a procedural language in PostgreSQL, the way PL/Perl and
PL/Python do for Perl and Python. A function body is Pure code. It runs in a
Pure interpreter (libpure) inside the backend process. From there it can
reach the database through SPI and Pure's library modules (math, gsl, mpfr,
csv, xml, ...).

It ships two languages, as PL/Perl does with plperl and plperlu:

- `pl_pure_untrusted` is untrusted and only superusers can use it. It ships
  first and works now.
- `pl_pure` is trusted. It is the language we ultimately ship. It needs a
  sandbox that libpure does not have yet (section 9), so for now its handler
  refuses to run: the extension and its grants exist, but a `pl_pure`
  function raises "pl_pure (trusted) is not available in this version".

The project, the repository and the shared library are called `pg_pure`
(`pg_pure.so`). The two SQL languages are `pl_pure` and
`pl_pure_untrusted`. One `.so` backs both. They are separate extensions
(`CREATE EXTENSION pl_pure`, `CREATE EXTENSION pl_pure_untrusted`): a DBA must
be able to install one without the other, and two extensions cannot own the
same handler function. Tom Lane hit this when plperl and plpython became
extensions:
https://pg.ddx.io/m/pgsql-hackers/27364.1299286724@sss.pgh.pa.us/

## 1a. Status, 2026-10-27

The untrusted language is built and passes. `pg_pure.c` (about 1080 lines)
backs both languages; `CREATE EXTENSION pl_pure_untrusted` then
`CREATE FUNCTION ... LANGUAGE pl_pure_untrusted` works, and its regression
suite (`sql/pl_pure_untrusted.sql`, 1 file) passes against PostgreSQL 18 on
the box with the version-script'd libpure. The six prototype defects in
section 8 are fixed and each has a regression case: exact numeric round-trips
(`12345678901234567890.123456789` in and out unchanged), an int2 result of
70000 is an ERROR, an int8 overflow is an ERROR, a non-string text result is
an ERROR, and a `;` in a body no longer leaks a global rule. The crash matrix
(PostgreSQL JIT and Pure in one backend, both orders, three runs each) shows
0 crashes. `pl_pure` is installable and refuses to run, as described above.
Still missing from phase 1: set-returning functions, triggers, preload
warm-up wired into `_PG_init` (the code is there but untested end to end),
and the TAP suite. See ROADMAP.md.

## 2. How users write Pure in PostgreSQL

### 2.1 Functions

```sql
CREATE EXTENSION pl_pure_untrusted;

CREATE FUNCTION hyp(a float8, b float8) RETURNS float8
LANGUAGE pl_pure_untrusted IMMUTABLE STRICT
AS $$ sqrt (a*a + b*b) $$;
```

A function body is a single Pure expression, and the SQL argument names are
its variables. Helpers go in an ordinary `with ... end` or `when ... end`
block:

```sql
CREATE FUNCTION fib(n int) RETURNS numeric LANGUAGE pl_pure_untrusted AS $$
  loop n 0L 1L with
    loop 0 a _ = a;
    loop k a b = loop (k-1) b (a+b)
  end
$$;
SELECT fib(100);              -- 354224848179261915075
```

A body can open with `using` declarations, which load Pure modules into the
backend's interpreter:

```sql
CREATE FUNCTION sd(xs float8[]) RETURNS float8 LANGUAGE pl_pure_untrusted AS $$
  using gsl;
  gsl::stats::sd (matrix xs)
$$;
```

Pure's distinctive feature is symbolic rewriting, and it is available in SQL:

```sql
CREATE FUNCTION simplify(e text) RETURNS text LANGUAGE pl_pure_untrusted AS $$
  str (reduce (val e) with
         x*1 = x; 1*x = x; 0*x = 0; x*0 = 0; x+0 = x; 0+x = x
       end)
$$;
SELECT simplify('x*1 + 0*y + (x+0)');   -- x+x
```

Argument names have to be valid Pure variable names. That excludes Pure
keywords (`case`, `end`, `of`, `type`, `when`, `with`, ...) and constant
symbols such as `true` and `false`. An argument called `true` would turn
into a constant pattern, so the function would reduce only when the argument
equals 1 and would silently return an unevaluated expression otherwise. The
validator rejects such names.

### 2.2 Types

| SQL type | Pure value passed in | Accepted on return |
|---|---|---|
| int2, int4 | machine int | int or bigint; out-of-range is an ERROR |
| int8 | bigint (`5L`) | int or bigint; out-of-range is an ERROR |
| numeric | bigint if integral, else an exact rational (`x%y`); NaN and Infinity as doubles | int, bigint, rational, double |
| float4, float8 | double | double, int, bigint, rational |
| bool | 1 or 0 (Pure's `true` and `false`) | int; nonzero is true |
| text, varchar, char, name | string, converted to UTF-8 | strings only |
| arrays | lists (nested lists for multi-dimensional arrays) | list or matrix |
| composite types, record | record `{"col"=>value, ...}` | record, or tuple in column order |
| NULL | `sql::null` | `sql::null` |
| any other type | its text form, as a string | a string, passed to the type's input function |

The table follows three rules:

- Nothing is lost silently. The prototype turned numeric into a double:
  `12345678901234567890.123456789` came back as `12345678901234600000`.
  It also returned 4464 for an int2 result of 70000, and gave
  `-9223372036709301616` for the int8 square of 3037000500. Each of these
  becomes either exact or an ERROR.
- A text result must be a string. In Pure, an application that no rule
  matches is a normal form: `take 5L xs` stays `take 5L xs`, because `take`
  wants a machine int. If any value were turned into text with `str`, a
  type mistake would come back as wrong text instead of an error.
- int2 and int4 map to Pure's own machine int, so prelude functions and
  literal patterns (`f 0 = ...`) work as Pure programmers expect. That
  brings Pure's machine-int behaviour with it: arithmetic wraps silently, as
  the Pure manual says (`2147483647 + 1` gives `-2147483648`). The result
  is range-checked on return, but a wrap inside the computation goes
  undetected. `pmul(65536, 65536)` with body `x*y+1` returns 1, where SQL
  would raise "integer out of range". See open question 2.

### 2.3 Set-returning functions

```sql
CREATE FUNCTION primes(n int) RETURNS SETOF int LANGUAGE pl_pure_untrusted AS $$
  take n (sieve (2..inf)) with
    sieve (p:qs) = p : sieve [q | q = qs; q mod p] &
  end
$$;
SELECT * FROM primes(10);
```

A set-returning function returns a list or a lazy stream. The handler forces
it one element at a time and writes each element into a tuplestore, which is
what the executor does with any set-returning function in FROM anyway
(`ExecMakeTableFunctionResult`). An infinite stream runs until
`statement_timeout` or a cancel stops it, since the interrupt hook is
checked while the stream is forced. For `RETURNS TABLE(...)` each element is
a tuple or a record.

### 2.4 Database access

Everything pg_pure adds to Pure lives in the namespace `sql`:

| Pure | Meaning |
|---|---|
| `sql::query q`, `sql::query (q, p1, p2, ...)` | run a query and return its rows as a list; a row is a tuple of column values, and a one-column row is the bare value |
| `sql::exec q`, `sql::exec (q, p1, ...)` | run a command and return the number of rows processed |
| `sql::notice msg`, `sql::warning msg` | send a message to the client |
| `sql::null` | SQL NULL |
| `sql::error sqlstate message` | the exception an SQL error turns into; throwing it raises that SQL error |

```sql
CREATE FUNCTION order_total(id int) RETURNS numeric LANGUAGE pl_pure_untrusted AS $$
  foldl (+) 0 [qty * price | (qty, price) =
     sql::query ("SELECT qty, price FROM line_item WHERE order_id = $1", id)]
$$;

CREATE FUNCTION add_user(email text) RETURNS bool LANGUAGE pl_pure_untrusted AS $$
  catch dup (sql::exec ("INSERT INTO users(email) VALUES ($1)", email) > 0)
  with dup (sql::error "23505" _) = false; dup e = throw e end
$$;
```

Parameters go to the server as text with no declared type, as libpq's
`PQexecParams` does when it is given no types. The server works out each
parameter's type from the query. Doubles are sent with 17 significant digits
so they round-trip exactly, lists go as array literals, and `sql::null` goes
as NULL. Callers pass parameters instead of splicing values into the SQL
string.

Each `sql::query` and `sql::exec` call runs in its own internal
subtransaction, as in PL/Python. If the statement fails, the subtransaction
is rolled back, which releases its locks, pins and cache references. The
SQL error then reaches Pure as the exception `sql::error sqlstate message`,
so Pure code can match on SQLSTATE (above, `23505` for a unique violation).
When Pure code catches the error, the transaction carries on. When it does
not, the original error is re-raised with its detail, hint and position
intact. Any other uncaught Pure exception becomes `ERROR: pl_pure_untrusted: uncaught
exception: <value>` with SQLSTATE 38000.

### 2.5 Triggers

```sql
CREATE FUNCTION line_total() RETURNS trigger LANGUAGE pl_pure_untrusted AS $$
  insert new ("total" => new!"qty" * new!"price")
$$;
CREATE TRIGGER line_total BEFORE INSERT OR UPDATE ON line_item
  FOR EACH ROW EXECUTE FUNCTION line_total();
```

A trigger body sees three variables:

- `new` and `old` are records, or `sql::null` when the operation has none.
- `tg` is a record with the keys "name", "when", "level", "op",
  "table_name", "table_schema" and "args".

In a row-level BEFORE trigger, returning a record makes it the row, and
returning `sql::null` skips the operation, which is PostgreSQL's own rule
(returning NULL means skip). PostgreSQL ignores the return value of
statement-level and AFTER triggers.

### 2.6 DO blocks and procedures

```sql
DO LANGUAGE pl_pure_untrusted $$
  sql::exec "UPDATE line_item SET total = qty * price WHERE total IS NULL"
$$;
```

A DO block is compiled as a temporary named function, called once and then
cleared, so its compiled code can be freed. `CREATE PROCEDURE ... LANGUAGE
pl_pure_untrusted` works with CALL. Transaction control inside procedures
(`sql::commit`, `sql::rollback`) is a later phase.

### 2.7 Configuration

- `shared_preload_libraries = 'pg_pure'` is recommended but not required.
  With it, the postmaster builds the interpreter once, loads the modules,
  warms up, and every backend inherits the result through fork. See
  section 3 for what that buys.
- `pg_pure.using` (default `'math'`) lists the modules every interpreter
  loads. Exact numeric needs `math` for rationals. It is read when the
  interpreter is created, so with preloading that happens at postmaster
  start.

That is the only setting. The prelude is found through libpure's built-in
library path, or through PURELIB in the server's environment.

## 3. Measured costs

| What | Measured |
|---|---|
| Create an interpreter with the prelude | 1.53 s, +87 MB RSS (3 runs) |
| Create an interpreter with `--noprelude` | 0.002 s, +4 MB |
| First call of the first function (LLVM compiles the prelude code the call reaches) | 1.91 to 1.94 s more (3 runs) |
| First pl_pure_untrusted call in a new backend, no preload | 5.24 to 5.33 s (5 runs) |
| Same, preloaded, no warm-up | 1.17 to 1.18 s |
| Same, preloaded and warmed in the postmaster | 0.16 to 0.17 s; 8 new backends in parallel take 0.24 s wall |
| Postmaster start with preload and warm-up | 5.5 s, 251 MB RSS |
| First call of each further new function | 72 to 165 ms |
| Backend private memory, preloaded | 2.5 MB at connect, 104.5 MB after the first Pure call, 110.9 MB after 1M calls |
| 1M calls of `x*y+1` in one SELECT (`jit = off`) | plain SQL 96 to 99 ms, PL/pgSQL 305 to 308 ms, pl_pure_untrusted 455 ms |
| 1M calls of string concatenation | PL/pgSQL 406 ms, pl_pure_untrusted 578 ms |
| One `pure_appv` call, outside PostgreSQL | 210 to 216 ns with machine-int arguments, 427 ns with bigint arguments |

What follows from the table:

- Preloading turns a 5.3 s first call into 0.16 s, so the docs recommend it
  and the tests cover both modes. A per-backend interpreter makes a
  connection pooler worth having either way.
- `pure_interp_compile(ip, 0)` ("compile everything") ran in 0.01 s and did
  not reduce the 1.9 s first call. The warm-up therefore has to run real
  code.
- The first call dirties about 100 MB of memory inherited from the
  postmaster. The likely cause is that Pure's reference counting writes into
  every shared expression it touches, and LLVM writes to its own state. I
  have not confirmed this.
- About 1.8 s of the 5.3 s cold first call is unexplained compared with the
  standalone 3.5 s (create plus first call). It is probably the prototype's
  `using math`, but I have not broken it down.

## 4. The engine

- **One interpreter per backend.** A backend creates it on first use or
  inherits it from the postmaster. libpure starts no threads (a process with
  a live interpreter has one thread), so forking with an interpreter in
  memory is safe. EXEC_BACKEND builds, which means Windows, cannot inherit
  it. `_PG_init` returns at once under `IsBinaryUpgrade`, as pg_cron's does.
- **Function cache.** Entries are keyed by function oid and validated by
  the pg_proc row's xmin and tid, as PL/Perl does. A function is compiled
  as `__pg_pure_<oid> a b = (<body>);`. The parentheses keep a stray `;`
  from defining globals. In the prototype, the body `x; helper y = y+100`
  defined `helper` for every other function in the backend. A recompile
  `clear`s the old rules first, because Pure appends new rules rather than
  replacing old ones.
- **Calls.** Arguments are converted before the call. The call goes through
  `pure_appxv`, and the result is converted after Pure has returned.
- **Boundary rules.** These are correctness invariants, carried over from
  the prototype and libpure's embedding contract:
  1. No PostgreSQL ERROR may longjmp through Pure frames. Every callback
     from Pure into PostgreSQL (SPI, notices, type I/O) runs under
     `PG_TRY`, and SPI calls also run in an internal subtransaction. A
     caught error turns into a Pure exception. The saved `ErrorData` is
     re-raised if Pure does not catch it.
  2. No Pure exception escapes into PostgreSQL. The x-variants return the
     exception value, and the handler turns it into `ereport` after the
     Pure call has returned. The value must be released with
     `pure_freenew`, not `pure_free`.
  3. Conversions that can raise an error run outside any Pure call.
  4. Cancel: the interrupt hook only reads `QueryCancelPending ||
     ProcDiePending`. After a failed call, `CHECK_FOR_INTERRUPTS()` lets
     PostgreSQL report its own cancel or terminate error.
  5. Stack: `pure_set_stack_limit(&frame, max_stack_depth / 2)` runs before
     each call, so runaway recursion becomes `stack_fault` and then an
     ERROR.
  6. Memory: Pure values live in Pure's malloc'd heap. The only Pure values
     kept across calls are the cached function closures.
- **libpure must not export LLVM symbols.** See section 5.

## 5. The LLVM symbol clash (blocking)

PGDG's PostgreSQL 17 and 18 packages for Debian 13 ship `llvmjit.so` linked
against libLLVM 19.1, while libpure links libLLVM 21.1. Both can end up in
the same backend: `jit = on` is the default, and PostgreSQL JIT-compiles any
query that costs more than `jit_above_cost` (100000).

libpure exports about 200 C++ symbols that are template instances over LLVM
types, for example
`std::_Sp_counted_ptr_inplace<llvm::orc::ThreadSafeContext::State, ...>::_M_dispose`.
The dynamic linker binds the other LLVM's references to libpure's copies.
When the backend exits, LLVM 19's ORC teardown runs code built against LLVM
21, and the backend dies with SIGSEGV. A backend crash makes the postmaster
restart every backend, so one crash takes down every session on the server.

The fix is to link libpure with `-Wl,-Bsymbolic` and a version script that
hides `*4llvm*` symbols, and to link the `pure` executable directly against
libLLVM, since it had been getting LLVM symbols through libpure. Each case
below ran on a fresh server with a fresh backend. A case counted only after
both query results came back correct:

| libpure build | Pure only | PG JIT only | Pure, then PG JIT | PG JIT, then Pure |
|---|---|---|---|---|
| stock | ok | ok | SIGSEGV | SIGSEGV |
| `-Bsymbolic` | ok | ok | SIGSEGV | ok |
| `-Bsymbolic` plus the version script (0 LLVM exports) | ok 3/3 | ok 3/3 | ok 3/3 | ok 3/3 |

With the fix, libpure's `make check` still passes 95 tests, the same as the
stock build, and `make check-embed` passes. The prototype's regression
output is unchanged with `jit_above_cost = 0`.

This is a libpure change, so it goes to the fork (open question 3). The
pg_pure test suite keeps a test that exercises PostgreSQL JIT and Pure in
the same backend, in both orders, and reads the server log for "terminated
by signal". Verified: with the fixed libpure, the pg_pure extension (not
just the prototype) runs the matrix 0-crash, 3 runs each, on a PG 18 server
with JIT forced on (`jit_above_cost = 0`).

### 5a. Two other ways to avoid the clash

The `-Bsymbolic` fix lets libpure (LLVM 21) and `llvmjit` (LLVM 19) coexist.
There are two situations where the fix is not even needed:

- **A PostgreSQL built without LLVM.** On Debian, `llvmjit.so` is a separate
  package (`postgresql-18-jit`). With it uninstalled, no backend ever loads
  libLLVM, and `jit = on` is silently a no-op. The stock libpure (LLVM
  symbols still exported) then runs 0-crash with `jit = on` and
  `jit_above_cost = 0` (verified). So one supported deployment is: install
  PostgreSQL without the JIT package, and pg_pure works with any libpure
  build. The server loses its own JIT, which for most pg_pure workloads is a
  fair trade.
- **A PostgreSQL built against the same LLVM major as libpure.** When the
  server's `llvmjit` and libpure both link libLLVM 21, there is one copy and
  no interposition. This is the path the LLVM-21 upgrade work makes
  available. Not yet tested here, because PGDG's `llvmjit` for Debian 13 is
  pinned to libLLVM 19; it will be exercised by the from-source cassert
  build in phase 1.8.

The `-Bsymbolic` fix is kept regardless, because it is the only option that
works with a stock PGDG server (LLVM 19) and an LLVM-21 libpure in the same
backend, and it costs nothing when the other two conditions also hold.

## 6. Pure behaviour users need to know

The docs explain each of these with an example:

- An application that no rule matches stays unevaluated. The result then
  fails to convert, and the error message says so with a hint: "check the
  argument types your rules expect; 5L is a bigint and does not match the
  pattern 5".
- Machine-int arithmetic wraps (section 2.2).
- `0L` does not match the pattern `0`, and `take 5L xs` does not reduce.
  int8 arguments arrive as bigints, so code should use `==` for
  comparisons or `int n` for the conversion.
- `str 3L` is `"3L"`. pg_pure's own conversions to SQL never add the `L`.
- Definitions made at run time with `eval` are not transactional and
  survive a ROLLBACK.
- A catch-all handler can catch the cancel exception. The cancel stays
  pending and PostgreSQL acts on it once the call returns, which I checked
  for one case (`catch (\_ -> -1) (loop n)` under `statement_timeout`).
  Loops that catch and keep going are untested.

## 7. Pure modules

Pure modules are scripts in PURELIB, often with a C shared object next to
them (for example `gsl.pure` and `gsl.so`). Users load them with
`pg_pure.using` or with a `using` line at the top of a body. Before a module
goes on the tested list, it is checked for process exits and aborts, signal
handlers, threads, writes to stdout, and global error handlers.

| Module | Status |
|---|---|
| math (prelude) | loaded by default, used for rationals |
| pure-gsl | turns off GSL's abort-on-error handler (`gsl_set_error_handler_off`). Builds on the box; `gsl::stats::mean` and `sd` work in standalone Pure. Not yet run inside PostgreSQL. |
| pure-mpfr, pure-csv, pure-xml, pure-stldict, pure-stllib, pure-rational | candidates for the tested list; not yet checked |
| pure-glpk | GLPK aborts the process on an internal error unless an error hook jumps out, and pure-glpk installs no such hook (found by reading the code). Needs a fix before use. |
| pure-ffi, pure-sql3, pure-odbc, pure-sockets | untrusted only, at the user's risk |
| gtk, tk, gl, audio, midi, faust, lv2, lilv, octave, avahi, bonjour (starts threads), fastcgi | out of scope |

Licenses: pg_pure itself is under the PostgreSQL license, like pg_fts and
pg_weave, and links libpure (LGPL-3) dynamically. pure-gsl, pure-glpk and
pure-rational are GPL. They are loaded by the user, not shipped with
pg_pure. This is not legal advice.

## 8. What the prototype gets wrong

Each item was reproduced on the box. v1 fixes all of them:

1. A `;` in a body defines global rules that other functions see.
2. numeric goes through double and loses digits.
3. int2 and int4 results are not range-checked (70000 comes back as 4464).
4. An int8 overflow returns a wrapped value instead of an error.
5. Any non-string result becomes text through `str`, so unevaluated
   expressions are returned as text.
6. It does not build on PostgreSQL 17: `max_stack_depth` lives in
   `tcop/tcopprot.h` there and in `miscadmin.h` in 18. With that one
   include fixed, its regression output is identical on 17 and 18.

## 9. The trusted language, `pl_pure`

A Pure program can call any C function through an `extern` declaration. The
standard prelude itself declares `system`, `popen`, `fopen` and `exit`, plus
`malloc`, `free` and pointer access. Pure also has inline C (`%< ... %>`,
which runs clang), `eval` and `evalcmd`, and `using` of any file on disk.
libpure has a `restricted` flag, but it only blocks a few interpreter
operations and is no sandbox. A trusted language therefore needs a "safe
mode" in libpure that:

- rejects `extern`, inline code, `eval` and `evalcmd`, and `using` outside
  an allowlist;
- loads a curated prelude without the system, posix and pointer modules;
- runs one interpreter per SQL user, as trusted PL/Perl does, so that
  SECURITY DEFINER functions cannot share state across users.

Each per-user interpreter costs the full creation price (1.5 s, about
100 MB) because an interpreter cannot be cloned. Any sandbox escape gives
the OS user that runs PostgreSQL to whoever can create functions. This is
the riskiest part of the project. It is a separate phase, and it starts only
after the libpure safe-mode design has been reviewed (open question 4).

## 10. Platforms

Tested (regression suite green, 0 backend crashes):

- **Linux (Debian 13)**, PostgreSQL 17, 18 and 19, libpure on LLVM 21.
- **FreeBSD 14.5**, PostgreSQL 17, libpure on LLVM 21. pg_pure built clean
  against the fork's libpure with no source change; the suite passed on a
  JIT-off cluster (FreeBSD's PG 17 llvmjit is LLVM 19, so the same
  coexistence rule applies as on Debian, section 5a).

Not planned:

- **Windows.** Three independent blockers, each checked, not assumed:
  (1) Windows backends use EXEC_BACKEND, not fork, so they cannot inherit a
  postmaster-built interpreter; `_PG_init` runs in each backend with
  `IsUnderPostmaster = true`, so the preload warm-up buys nothing and every
  backend pays the full ~5 s interpreter creation. (2) A Windows libpure
  exists only on the fork's unmerged `msvc-port` branch (PR #50), built with
  MSVC/CMake; mixing that with a MinGW-built PostgreSQL in one process is an
  ABI hazard. (3) The embedding contract (no process exit, host hooks) was
  validated only on POSIX. santorini (Windows 11 ARM64) has clang 20 and a
  PostgreSQL 16 from Strawberry Perl, neither of which matches what a port
  would need. Revisit only if there is a real user.
- Background workers or scheduling written in Pure. pg_cron contributed
  only the `_PG_init` preload pattern and the GUC conventions.
- Multithreaded PostgreSQL.
- Custom aggregates and operators need no extra work: they call ordinary
  functions.

## 11. Open questions

1. **Naming.** Decided (Greg, 2026-10-27): `pl_pure` is the trusted
   language and the one we ship; `pl_pure_untrusted` is the superuser-only
   one. Both are separate extensions over the one `pg_pure.so`.
2. **int4 semantics.** Still open. One option is Pure's machine ints: wraps
   go undetected inside a computation (the result is still range-checked on
   return), but the prelude and literal patterns (`f 0 = ...`) work. The
   other is to pass every integer as a bigint: SQL-style overflow errors,
   about 2x the per-call cost (427 ns against 216 ns), and `take n xs` or
   `f 0 = ...` stop working for SQL integers. The built extension uses
   machine ints for int2/int4 and bigints for int8.
3. **Where the libpure symbol fix lands.** It could be a new commit on PR
   #48's branch (the PR is titled "Make libpure.so safe to embed in a host
   that owns the process") or a separate PR. Greg is separately moving
   PostgreSQL to LLVM 21, which removes the clash for a from-source server
   (section 5a); the fix is still wanted for stock PGDG servers.
4. **The trusted language.** `pl_pure` is the ship target, so the libpure
   safe mode (section 9) is on the critical path, not optional. The
   remaining question is only whether safe mode is designed with the Pure
   maintainer upstream or carried in the fork.
