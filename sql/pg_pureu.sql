CREATE EXTENSION pg_pureu;

-- arithmetic and argument passing
CREATE FUNCTION pmul(x int, y int) RETURNS int LANGUAGE pg_pureu AS 'x*y+1';
SELECT pmul(6, 7);
SELECT pmul(i, i) FROM generate_series(1, 5) i;

-- int8, float8, text, bool
CREATE FUNCTION pbig(n int8) RETURNS int8 LANGUAGE pg_pureu AS 'n*n';
SELECT pbig(3000000000);
CREATE FUNCTION phyp(a float8, b float8) RETURNS float8 LANGUAGE pg_pureu AS 'sqrt (a*a+b*b)';
SELECT phyp(3, 4);
CREATE FUNCTION pcat(a text, b text) RETURNS text LANGUAGE pg_pureu AS 'a + " & " + b';
SELECT pcat('Hello', 'Pure');
CREATE FUNCTION peven(n int) RETURNS bool LANGUAGE pg_pureu AS 'n mod 2 == 0';
SELECT peven(4), peven(5);

-- recursion and pattern matching in a local definition
CREATE FUNCTION pfib(n int) RETURNS int8 LANGUAGE pg_pureu AS
  'fib n with fib 0 = 0; fib 1 = 1; fib n = fib (n-1) + fib (n-2) end';
SELECT pfib(25);

-- a list built in Pure, returned as text
CREATE FUNCTION plist(n int) RETURNS text LANGUAGE pg_pureu AS 'str [k*k | k = 1..n]';
SELECT plist(6);

-- exact numeric in and out (DESIGN.md section 2.2): no rounding
CREATE FUNCTION pnumid(x numeric) RETURNS numeric LANGUAGE pg_pureu AS 'x';
SELECT pnumid(12345678901234567890.123456789);
CREATE FUNCTION phalf(x numeric) RETURNS numeric LANGUAGE pg_pureu AS 'using math; x/2';
SELECT phalf(5);

-- range checks on return (prototype returned wrong numbers here)
CREATE FUNCTION pi2(x int) RETURNS int2 LANGUAGE pg_pureu AS 'x';
SELECT pi2(70000);
CREATE FUNCTION psq8(n int8) RETURNS int8 LANGUAGE pg_pureu AS 'n*n';
SELECT psq8(3037000500);

-- a text result must be a Pure string; an unmatched application is an error,
-- not wrong text
CREATE FUNCTION pbadtext(x int) RETURNS text LANGUAGE pg_pureu AS 'f x with f 1 = "one" end';
SELECT pbadtext(1);
SELECT pbadtext(2);

-- NULL in and out
CREATE FUNCTION pnull(x int) RETURNS int LANGUAGE pg_pureu AS
  'case x of sql::null = 0; _ = x+1 end';
SELECT pnull(NULL), pnull(41);
CREATE FUNCTION pmknull(x int) RETURNS int LANGUAGE pg_pureu AS 'if x > 0 then x else sql::null';
SELECT pmknull(1) IS NULL AS one_null, pmknull(-1) IS NULL AS minus_null;

-- a zero-argument function
CREATE FUNCTION pzero() RETURNS int LANGUAGE pg_pureu AS '42';
SELECT pzero();

-- a ';' in a body must NOT leak a global rule into other functions
-- a ';' in a body cannot define a global rule other functions could see.
-- The body is wrapped in parentheses, so a ';' makes it a compile error at
-- CREATE time rather than silently leaking a 'helper' definition.
CREATE FUNCTION pleaka(x int) RETURNS int LANGUAGE pg_pureu AS 'x; helper y = y + 100';
-- helper never became global, so a function that references it does not compile
CREATE FUNCTION pleakb(x int) RETURNS int LANGUAGE pg_pureu AS 'helper x';
SELECT pleakb(1);   -- expected: result is unevaluated 'helper 1', a type error

-- an uncaught Pure exception becomes an SQL error; the session keeps working
CREATE FUNCTION pthrow(x int) RETURNS int LANGUAGE pg_pureu AS 'throw (my_error x)';
SELECT pthrow(7);
SELECT pmul(2, 3);

-- a result that does not fit the return type
CREATE FUNCTION pbad(x int) RETURNS int LANGUAGE pg_pureu AS '"not an int"';
SELECT pbad(1);

-- a compile error is reported by the validator at CREATE time
CREATE FUNCTION psyntax(x int) RETURNS int LANGUAGE pg_pureu AS 'x +* 1';

-- runaway recursion is a stack_fault exception, not a crash
CREATE FUNCTION pdeep(n int) RETURNS int LANGUAGE pg_pureu AS
  'd n with d 0 = 0; d n = 1 + d (n-1) end';
SELECT pdeep(1000);
SELECT pdeep(100000000);
SELECT pdeep(10);

-- statement_timeout cancels a Pure loop
CREATE FUNCTION ploop(n int) RETURNS int LANGUAGE pg_pureu AS
  'loop n with loop n = loop (n+1) end';
SET statement_timeout = '1s';
SELECT ploop(0);
RESET statement_timeout;
SELECT pmul(3, 3);

-- CREATE OR REPLACE recompiles; the old rules do not linger
CREATE OR REPLACE FUNCTION pmul(x int, y int) RETURNS int LANGUAGE pg_pureu AS 'x*y';
SELECT pmul(6, 7);

-- SPI: query and command from Pure, with parameters
CREATE TABLE t (k int, v text);
INSERT INTO t VALUES (1, 'one'), (2, 'two'), (3, 'three');
CREATE FUNCTION pcount() RETURNS int LANGUAGE pg_pureu AS
  '#sql::query "SELECT k FROM t"';
SELECT pcount();
CREATE FUNCTION psum() RETURNS int LANGUAGE pg_pureu AS
  'foldl (+) 0 (sql::query "SELECT k FROM t")';
SELECT psum();
CREATE FUNCTION prows() RETURNS text LANGUAGE pg_pureu AS
  'str (sql::query "SELECT k, v FROM t ORDER BY k")';
SELECT prows();

-- an SQL error inside SPI reaches the client as that SQL error
CREATE FUNCTION pbadsql() RETURNS int LANGUAGE pg_pureu AS
  'sql::exec "SELECT * FROM no_such_table"';
SELECT pbadsql();
SELECT pmul(5, 5);

-- Pure can catch the SQL error by SQLSTATE; the transaction continues
CREATE FUNCTION pcatch() RETURNS text LANGUAGE pg_pureu AS
  'catch (\(sql::error st _) -> "caught " + st) (sql::exec "SELECT 1/0")';
SELECT pcatch();

-- sql::notice reaches the client
CREATE FUNCTION psay(m text) RETURNS int LANGUAGE pg_pureu AS
  'sql::notice m $$ 0';
SELECT psay('hello from pure');

-- a DO block
DO LANGUAGE pg_pureu $$ sql::exec "CREATE TEMP TABLE do_marker (ok int)" $$;
SELECT count(*) FROM do_marker;

-- unsupported types are rejected up front
CREATE FUNCTION pjson(x json) RETURNS int LANGUAGE pg_pureu AS '1';

-- the trusted language exists but refuses to run in this version
CREATE EXTENSION pg_pure;
CREATE FUNCTION ptrusted(x int) RETURNS int LANGUAGE pg_pure AS 'x+1';
SELECT ptrusted(1);

-- many calls of a compiled function in one statement
SELECT sum(pmul(i, 2)) FROM generate_series(1, 100000) i;
