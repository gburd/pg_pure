-- bench/setup.sql -- define the same three workloads in each procedural
-- language, so the harness can time them head to head.  Load this into a
-- database that has pg_pureu, plpython3u and plperlu installed.  pg_pureu is
-- the untrusted language (it can load the gsl module); the comparison is
-- apples to apples because every variant computes the same result.
--
-- The three workloads:
--   fib(n)        -- recursion and small-integer arithmetic (function-call
--                    and dispatch cost dominates)
--   hsum(n)       -- a numeric sum over a series (exact-rational / numeric
--                    conversion cost shows here)
--   chol(a, b)    -- a dense SPD linear solve over float8[] (the case the
--                    README claims pg_pure wins via the compiled gsl routine)

CREATE EXTENSION IF NOT EXISTS pg_pureu;
CREATE EXTENSION IF NOT EXISTS plpython3u;
CREATE EXTENSION IF NOT EXISTS plperlu;

-- ---- fib -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fib_plpgsql(n int) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE a bigint := 0; b bigint := 1; t bigint; i int;
BEGIN
  FOR i IN 1..n LOOP t := a + b; a := b; b := t; END LOOP;
  RETURN a;
END $$;

CREATE OR REPLACE FUNCTION fib_plpython(n int) RETURNS bigint LANGUAGE plpython3u AS $$
a, b = 0, 1
for _ in range(n):
    a, b = b, a + b
return a
$$;

CREATE OR REPLACE FUNCTION fib_plperl(n int) RETURNS bigint LANGUAGE plperlu AS $$
my ($n) = @_;
my ($a, $b) = (0, 1);
for (1..$n) { ($a, $b) = ($b, $a + $b); }
return $a;
$$;

CREATE OR REPLACE FUNCTION fib_pure(n int) RETURNS bigint LANGUAGE pg_pureu AS
  $PURE$ loop n 0L 1L with loop 0 a _ = a; loop k a b = loop (k-1) b (a+b) end $PURE$;

-- ---- hsum: sum of i*i for i in 1..n, returned as numeric --------------------
CREATE OR REPLACE FUNCTION hsum_plpgsql(n int) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE s numeric := 0; i int;
BEGIN
  FOR i IN 1..n LOOP s := s + i::numeric * i::numeric; END LOOP;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION hsum_plpython(n int) RETURNS numeric LANGUAGE plpython3u AS $$
return sum(i * i for i in range(1, n + 1))
$$;

CREATE OR REPLACE FUNCTION hsum_plperl(n int) RETURNS numeric LANGUAGE plperlu AS $$
my ($n) = @_;
my $s = 0;
for my $i (1..$n) { $s += $i * $i; }
return $s;
$$;

CREATE OR REPLACE FUNCTION hsum_pure(n int) RETURNS numeric LANGUAGE pg_pureu AS
  $PURE$ foldl (+) 0L [k*k | k = 1L..(bigint n)] $PURE$;

-- ---- chol: solve A x = b for a 3x3 SPD A over float8[] ----------------------
-- PL/pgSQL does a hand-written Cholesky; pg_pure calls the compiled
-- gsl::linalg::cholesky_solve.  The DBA pre-allowlists the module for the
-- trusted language via pg_pure.using; pg_pureu may load it directly.
CREATE OR REPLACE FUNCTION chol_plpgsql(a float8[], b float8[]) RETURNS float8[]
LANGUAGE plpgsql AS $$
DECLARE
  nn int := array_length(b, 1);
  l float8[] := array_fill(0.0, ARRAY[nn, nn]);
  y float8[] := array_fill(0.0, ARRAY[nn]);
  x float8[] := array_fill(0.0, ARRAY[nn]);
  s float8; i int; j int; k int;
BEGIN
  FOR i IN 1..nn LOOP
    FOR j IN 1..i LOOP
      s := a[i][j];
      FOR k IN 1..j-1 LOOP s := s - l[i][k] * l[j][k]; END LOOP;
      IF i = j THEN l[i][j] := sqrt(s);
      ELSE l[i][j] := s / l[j][j]; END IF;
    END LOOP;
  END LOOP;
  FOR i IN 1..nn LOOP
    s := b[i];
    FOR k IN 1..i-1 LOOP s := s - l[i][k] * y[k]; END LOOP;
    y[i] := s / l[i][i];
  END LOOP;
  FOR i IN REVERSE nn..1 LOOP
    s := y[i];
    FOR k IN i+1..nn LOOP s := s - l[k][i] * x[k]; END LOOP;
    x[i] := s / l[i][i];
  END LOOP;
  RETURN x;
END $$;

CREATE OR REPLACE FUNCTION chol_pure(a float8[], b float8[]) RETURNS float8[]
  LANGUAGE pg_pureu AS $PURE$ using gsl::linalg; gsl::linalg::cholesky_solve a b $PURE$;
