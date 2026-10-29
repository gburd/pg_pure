CREATE EXTENSION IF NOT EXISTS pg_pure;

-- pg_pure is the TRUSTED language: a non-superuser may create functions, and
-- the sandbox (libpure --safe, armed) stops a body escaping the language.

-- a normal trusted function works
CREATE FUNCTION tmul(x int, y int) RETURNS int LANGUAGE pg_pure AS 'x*y+1';
SELECT tmul(6, 7);

-- exact bigint / numeric, same as pg_pureu
CREATE FUNCTION tfact(n int) RETURNS numeric LANGUAGE pg_pure AS 'foldl (*) 1L (1..n)';
SELECT tfact(20);

-- a vetted module on the allowlist (math, loaded by default) is usable
CREATE FUNCTION thalf(x numeric) RETURNS numeric LANGUAGE pg_pure AS 'using math; x/2';
SELECT thalf(5);

-- SPI works in the trusted language too
CREATE TABLE tt (k int);
INSERT INTO tt VALUES (10), (20), (30);
CREATE FUNCTION tsum() RETURNS int LANGUAGE pg_pure AS
  'foldl (+) 0 (sql::query "SELECT k FROM tt")';
SELECT tsum();

-- NULL and the sql namespace behave as in pg_pureu
CREATE FUNCTION tnull(x int) RETURNS int LANGUAGE pg_pure AS
  'case x of sql::null = -1; _ = x end';
SELECT tnull(NULL), tnull(5);

-- --- the sandbox refuses every route out of the language ---------------
-- Each of these must raise an SQL ERROR (not crash the backend), and a normal
-- call must still work afterward.

-- an extern declaration is refused at compile time
CREATE FUNCTION textern(x int) RETURNS int LANGUAGE pg_pure AS
  'x with f = extern int system(char*) end';
SELECT tmul(2, 2);   -- backend survived

-- eval is refused
CREATE FUNCTION teval(x int) RETURNS int LANGUAGE pg_pure AS 'eval "1+1"';
SELECT teval(1);
SELECT tmul(2, 2);

-- a dangerous prelude function (exit) never bound, so a call to it does not
-- terminate the backend; it is an unevaluated normal form, rejected as a type
-- mismatch, and the session keeps working
CREATE FUNCTION texit(x int) RETURNS int LANGUAGE pg_pure AS 'exit 1';
SELECT texit(1);
SELECT tmul(2, 2);   -- the backend is still alive

-- malloc is likewise unavailable: in safe mode it never binds to C, so
-- "malloc 8" stays the unevaluated symbol (str shows "malloc 8", not a
-- #<pointer ...>), proving no allocation happened. The backend survives.
CREATE FUNCTION tmalloc(x int) RETURNS text LANGUAGE pg_pure AS 'str (malloc 8)';
SELECT tmalloc(1);
SELECT tmul(2, 2);

-- using a native module (lib:) is refused at compile time
CREATE FUNCTION tnative(x int) RETURNS int LANGUAGE pg_pure AS
  'using "lib:nonesuch"; x';

-- using a module not on the allowlist is refused at compile time
CREATE FUNCTION tsys(x int) RETURNS int LANGUAGE pg_pure AS 'using system; x';
SELECT tmul(2, 2);   -- still alive after all of the above
