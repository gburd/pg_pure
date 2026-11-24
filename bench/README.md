# pg_pure benchmarks

A head-to-head timing of pg_pure against the three procedural languages a
PostgreSQL user would compare it with: PL/pgSQL, PL/Python (plpython3u) and
PL/Perl (plperlu).  The point is not a single "faster/slower" verdict but to
show where pg_pure wins, where it loses, and the one cost that dominates its
real-world behavior.

## Running it

On a host with PostgreSQL (plus the plpython3 and plperl packages) and libpure
installed, with pg_pure built and installed:

```sh
psql -f bench/setup.sql          # defines the same workloads in each language
PGBIN=/usr/lib/postgresql/18/bin PORT=5494 bash bench/run.sh
```

`setup.sql` defines three workloads in each language so the comparison is like
for like:

- `fib(n)` - iterative Fibonacci: recursion and small-integer arithmetic, where
  per-call dispatch cost dominates.
- `hsum(n)` - sum of `i*i` returned as numeric: exact-number conversion cost.
- `chol(A, b)` - a 3x3 symmetric-positive-definite solve over `float8[]`.  The
  PL/pgSQL version is a hand-written Cholesky; the pg_pure version calls the
  compiled `gsl::linalg::cholesky_solve`.  (No PL/Python or PL/Perl variant: the
  point is pg_pure's compiled-C path against hand-written SQL.)

## Method

- `warm` is the steady-state cost: a single backend calls the function 200
  times to compile it, then the harness times 20000 calls, median of 7
  interleaved repetitions.  This is the cost once a backend is warm.
- `cold` is the first-call latency: one call in a brand-new connection, which
  includes the one-time LLVM compile of that function.
- Figures are server executor time (`EXPLAIN ANALYZE`), so client round-trip
  and result formatting are excluded.

Each run records its box, instance type, PostgreSQL version, date and loop
size.  `results-YYYY-MM-DD.txt` holds a captured run on all three supported
PostgreSQL versions.

## What the numbers say (c7i.4xlarge, Debian 13, 2026-11-24)

pg_pure's cost is bimodal, and both halves matter.

**Cold first call is expensive.**  The first call to a given pg_pure function
in a backend compiles it with LLVM, which takes about **9 seconds** on this
box.  PL/pgSQL, PL/Python and PL/Perl all start a function in under 15 ms.
Preloading warms the postmaster, but a forked backend does not inherit the
warmed codegen (ROADMAP 1.6), so every new connection pays this once per
distinct function.  A connection pooler that keeps backends alive is the
practical answer; without one, pg_pure suits long-lived connections that call
a function many times, not one-shot connections.

**Warm steady state is a mixed result.**

| workload | pg_pure | PL/pgSQL | PL/Python | PL/Perl |
|----------|--------:|---------:|----------:|--------:|
| fib  (us/call)  |   9.7 |  4.1 |  1.8 |  2.8 |
| hsum (us/call)  |  97.8 | 17.6 |  4.5 |  3.2 |
| chol (us/call)  |   1.6 |  6.0 |   -  |   -  |

- On scalar recursion (`fib`), pg_pure is 2x to 5x slower than the others.
- On exact-number work (`hsum`), pg_pure is far slower: its numbers are exact
  rationals promoted through GMP and converted to `numeric`, which costs more
  than native integer or float arithmetic.
- On the compiled-C path (`chol`), pg_pure is about **4x faster** than a
  hand-written PL/pgSQL Cholesky, because the work happens in GSL's compiled
  routine and Pure is only the glue.

The honest summary: pg_pure is not a drop-in speed win.  Its draw is
expressiveness (term rewriting, pattern matching, exact rationals, lazy
streams, symbolic work) and reaching compiled numerical libraries, not raw
per-call throughput.  Where it calls into compiled C it can beat hand-written
SQL; on scalar or exact-number loops it is slower, and every cold backend pays
a large one-time compile.

An earlier note claimed the Cholesky binding was "~40x faster than PL/pgSQL."
That figure came from a single warmed call measured in one session and did not
account for the cold compile or a fair per-call comparison.  The measured warm
advantage is about 4x; see CHANGELOG under Retracted.
