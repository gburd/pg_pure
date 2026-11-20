# t/005_plan_cache.pl -- the SPI plan cache (ROADMAP 2.1) must speed up a
# repeated parameterized query without ever changing its answer. These tests
# guard correctness, which is the risk: a cache that hands one call another
# call's plan returns a wrong answer or a type error.
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('plancache');
$node->init;
$node->append_conf('postgresql.conf', "pg_pure.using = 'math'\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');

# --- 1. The key includes the inferred parameter types. -------------------
# The same SQL text called with an int parameter and with a double parameter
# must each plan and run correctly. If the cache keyed on text alone, the
# second call would reuse the first call's (wrong-typed) plan. "SELECT $1 + 1"
# with an int8 param returns a bigint (shown by str as 11L); with a float8
# param it returns a double (3.5).
$node->safe_psql('postgres',
	q{CREATE FUNCTION add1_any(x int, y float8) RETURNS text LANGUAGE pg_pureu AS }
	  . q{$P$ str (sql::query ("SELECT $1 + 1", [x])) + " / " + str (sql::query ("SELECT $1 + 1", [y])) $P$});
is($node->safe_psql('postgres', 'SELECT add1_any(10, 2.5)'),
	'[11L] / [3.5]',
	'the same query text with int and with double params gives each the right plan');

# Interleaved int and double uses of one text, many times, so a stale cached
# plan would surface as a wrong value.
$node->safe_psql('postgres',
	q{CREATE FUNCTION echo_i(n int) RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ case sql::query ("SELECT $1", [n]) of x:_ = x end $P$});
$node->safe_psql('postgres',
	q{CREATE FUNCTION echo_f(x float8) RETURNS float8 LANGUAGE pg_pureu AS }
	  . q{$P$ case sql::query ("SELECT $1", [x]) of v:_ = v end $P$});
is($node->safe_psql('postgres',
	q{SELECT string_agg(echo_i(g)::text || ':' || echo_f(g + 0.5)::text, ',') FROM generate_series(1,4) g}),
	'1:1.5,2:2.5,3:3.5,4:4.5',
	'interleaved int and double uses of the same text stay correct');

# --- 2. A repeated query in a loop stays correct over many iterations. ---
$node->safe_psql('postgres', 'CREATE TABLE nums (k int)');
$node->safe_psql('postgres', 'INSERT INTO nums SELECT generate_series(1,50)');
$node->safe_psql('postgres',
	q{CREATE FUNCTION count_ge(lo int) RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ case sql::query ("SELECT count(*)::int FROM nums WHERE k >= $1", [lo]) of x:_ = x end $P$});
is($node->safe_psql('postgres',
	q{SELECT string_agg(count_ge(g)::text, ',') FROM generate_series(48,50) g}),
	'3,2,1',
	'a parameterized query reused across calls returns correct counts');

# --- 3. DDL on a referenced object invalidates the cached plan. ----------
$node->safe_psql('postgres', 'CREATE TABLE t_ddl (a int)');
$node->safe_psql('postgres', 'INSERT INTO t_ddl VALUES (1)');
$node->safe_psql('postgres',
	q{CREATE FUNCTION star_ddl(k int) RETURNS text LANGUAGE pg_pureu AS }
	  . q{$P$ str (sql::query ("SELECT * FROM t_ddl WHERE a = $1", [k])) $P$});
is($node->safe_psql('postgres', 'SELECT star_ddl(1)'), '[1]',
	'plan over t_ddl before DDL returns one column');
$node->safe_psql('postgres', 'ALTER TABLE t_ddl ADD COLUMN b int DEFAULT 9');
is($node->safe_psql('postgres', 'SELECT star_ddl(1)'), '[(1,9)]',
	'after ALTER TABLE the reused query reflects the new column (plan revalidated)');

# --- 4. search_path change routes an unqualified name to a new table. ----
$node->safe_psql('postgres', 'CREATE SCHEMA s1');
$node->safe_psql('postgres', 'CREATE TABLE s1.w (v int)');
$node->safe_psql('postgres', 'INSERT INTO s1.w VALUES (111)');
$node->safe_psql('postgres', 'CREATE SCHEMA s2');
$node->safe_psql('postgres', 'CREATE TABLE s2.w (v int)');
$node->safe_psql('postgres', 'INSERT INTO s2.w VALUES (222)');
$node->safe_psql('postgres',
	q{CREATE FUNCTION read_w(k int) RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ case sql::query ("SELECT v FROM w WHERE v > $1", [k]) of x:_ = x end $P$});
is($node->safe_psql('postgres', 'SET search_path = s1, public; SELECT read_w(0)'),
	'111', 'unqualified w resolves to s1.w under its search_path');
is($node->safe_psql('postgres', 'SET search_path = s2, public; SELECT read_w(0)'),
	'222', 'the same text under a different search_path resolves to s2.w (plan revalidated)');

$node->stop('fast');
my $log = slurp_file($node->logfile);
my $crashes = () = $log =~ /was terminated by signal/g;
is($crashes, 0, 'no backend crashed during the plan-cache tests');

done_testing();
