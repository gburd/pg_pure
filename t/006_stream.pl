# t/006_stream.pl -- sql::stream is a lazy, cursor-backed result that a body
# can consume row-by-row without materializing the whole result. Its one hard
# safety property (ROADMAP 2.2): a stream forced after the function call that
# created it has returned must THROW, never crash. The stream is valid only
# within its call; call_function closes the cursor and bumps an epoch on the
# way out, so a stale handle forced later fails a check and raises a Pure
# sql::error.
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('stream');
$node->init;
$node->append_conf('postgresql.conf', "pg_pure.using = 'math'\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');
$node->safe_psql('postgres', 'CREATE TABLE big (k int)');
$node->safe_psql('postgres', 'INSERT INTO big SELECT generate_series(1,500)');

# --- consuming a stream gives the same rows as the query ------------------
$node->safe_psql('postgres',
	q{CREATE FUNCTION ssum() RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ foldl (+) 0 (sql::stream "SELECT k FROM big ORDER BY k") $P$});
is($node->safe_psql('postgres', 'SELECT ssum()'), '125250',
	'a stream summed over 500 rows equals sum(1..500)');

# --- laziness: take a few rows of a large stream without reading it all ---
$node->safe_psql('postgres',
	q{CREATE FUNCTION sfirst3() RETURNS text LANGUAGE pg_pureu AS }
	  . q{$P$ str (list (take 3 (sql::stream "SELECT k FROM big ORDER BY k"))) $P$});
is($node->safe_psql('postgres', 'SELECT sfirst3()'), '[1,2,3]',
	'take 3 of a 500-row stream yields the first three rows');

# --- parameterized stream -------------------------------------------------
$node->safe_psql('postgres',
	q{CREATE FUNCTION sge(lo int) RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ foldl (+) 0 (sql::stream ("SELECT k FROM big WHERE k >= $1", [lo])) $P$});
is($node->safe_psql('postgres', 'SELECT sge(498)'), '1497',
	'a parameterized stream sums 498+499+500');

# --- multi-column rows, and an empty result -------------------------------
$node->safe_psql('postgres',
	q{CREATE FUNCTION spairs() RETURNS text LANGUAGE pg_pureu AS }
	  . q{$P$ str (list (take 2 (sql::stream "SELECT k, k*k FROM big ORDER BY k"))) $P$});
is($node->safe_psql('postgres', 'SELECT spairs()'), '[(1,1),(2,4)]',
	'a multi-column stream yields tuples');
$node->safe_psql('postgres',
	q{CREATE FUNCTION sempty() RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ foldl (+) 0 (sql::stream "SELECT k FROM big WHERE k > 9999") $P$});
is($node->safe_psql('postgres', 'SELECT sempty()'), '0',
	'an empty-result stream is the empty list');

# --- two streams live at once in one body ---------------------------------
$node->safe_psql('postgres',
	q{CREATE FUNCTION stwo() RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ (foldl (+) 0 (sql::stream "SELECT k FROM big WHERE k <= 5")) }
	  . q{+ (foldl (+) 0 (sql::stream "SELECT k FROM big WHERE k <= 3")) $P$});
is($node->safe_psql('postgres', 'SELECT stwo()'), '21',
	'two concurrent streams in one body each read correctly');

# --- many calls: each opens and closes its own cursor, no leak ------------
$node->safe_psql('postgres',
	q{CREATE FUNCTION s10() RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ foldl (+) 0 (sql::stream "SELECT k FROM big WHERE k <= 10") $P$});
is($node->safe_psql('postgres', 'SELECT sum(s10()) FROM generate_series(1,100)'),
	'5500', '100 stream-using calls each read correctly (cursors do not leak)');

# --- THE SAFETY PROPERTY: a stream forced after its call returned throws ---
# A function hands back a raw stream handle (its call then ends, closing the
# cursor and bumping the epoch). A later call that forces that stale handle
# must raise a Pure sql::error, and the backend must survive.
$node->safe_psql('postgres',
	q{CREATE FUNCTION sopen() RETURNS int LANGUAGE pg_pureu AS }
	  . q{$P$ sql::stream_open_ "SELECT k FROM big" [] $P$});
$node->safe_psql('postgres', 'SELECT sopen()');    # opens handle 0, call ends -> closed
$node->safe_psql('postgres',
	q{CREATE FUNCTION sforce(h int) RETURNS text LANGUAGE pg_pureu AS }
	  . q{$P$ str (sql::stream_fetch_ h) $P$});
my ($rc, $out, $err) = $node->psql('postgres', 'SELECT sforce(0)', on_error_stop => 0);
like($err, qr/sql::error|stream|invalid/,
	'forcing a stale stream handle raises an error, not a crash');
is($node->safe_psql('postgres', 'SELECT ssum()'), '125250',
	'the backend survives the stale-handle force and still streams');

$node->stop('fast');
my $log = slurp_file($node->logfile);
my $crashes = () = $log =~ /was terminated by signal/g;
is($crashes, 0, 'no backend crashed during the stream tests (never a use-after-free)');

done_testing();
