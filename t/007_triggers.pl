# t/007_triggers.pl -- DML trigger support (ROADMAP 3.4, DESIGN 2.5). A
# trigger body sees three variables: new and old (the row records, or sql::null
# when the event has no such row) and tg (a record describing the event). A
# BEFORE-row body returns a record to become the stored row (omitted columns
# keep the original value), or sql::null to skip the operation. AFTER and
# statement bodies ignore the return. The hard safety property: a body that
# returns the wrong thing, names a column that does not exist, or tries the
# single-expression escape must raise a clean error, never crash the backend.
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('triggers');
$node->init;
$node->append_conf('postgresql.conf', "pg_pure.using = 'math'\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');
$node->safe_psql('postgres',
	'CREATE TABLE item (id int, qty int, price numeric, total numeric)');

# --- BEFORE INSERT: compute a column, leave the others alone --------------
# The body overrides only "total"; id, qty and price keep the inserted values.
$node->safe_psql('postgres',
	q{CREATE FUNCTION fill_total() RETURNS trigger LANGUAGE pg_pureu AS }
	  . q{$P$ insert new ("total" => new!"qty" * new!"price") $P$});
$node->safe_psql('postgres',
	'CREATE TRIGGER t_ins BEFORE INSERT ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION fill_total()');
$node->safe_psql('postgres',
	'INSERT INTO item (id, qty, price) VALUES (1, 3, 5.0), (2, 10, 2.5)');
is($node->safe_psql('postgres',
		"SELECT string_agg(total::text, ',' ORDER BY id) FROM item"),
	'15,25', 'BEFORE INSERT computed total, other columns intact');

# --- BEFORE UPDATE: new and old are both the row records ------------------
$node->safe_psql('postgres',
	'CREATE TRIGGER t_upd BEFORE UPDATE ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION fill_total()');
$node->safe_psql('postgres', 'UPDATE item SET qty = 4 WHERE id = 1');
is($node->safe_psql('postgres', 'SELECT total FROM item WHERE id = 1'),
	'20', 'BEFORE UPDATE recomputed total from the new qty');

# old carries the pre-update row; a body can read it.
$node->safe_psql('postgres',
	q{CREATE FUNCTION keep_old_price() RETURNS trigger LANGUAGE pg_pureu AS }
	  . q{$P$ insert new ("price" => old!"price") $P$});
$node->safe_psql('postgres', 'DROP TRIGGER t_upd ON item');
$node->safe_psql('postgres',
	'CREATE TRIGGER t_upd2 BEFORE UPDATE ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION keep_old_price()');
$node->safe_psql('postgres', 'UPDATE item SET price = 99.0 WHERE id = 2');
is($node->safe_psql('postgres', 'SELECT price FROM item WHERE id = 2'),
	'2.5', 'old is visible in a BEFORE UPDATE body (the price change was reverted)');
$node->safe_psql('postgres', 'DROP TRIGGER t_upd2 ON item');

# --- BEFORE INSERT returning sql::null skips the row (no error) -----------
$node->safe_psql('postgres',
	q{CREATE FUNCTION reject_big() RETURNS trigger LANGUAGE pg_pureu AS }
	  . q{$P$ if new!"qty" > 100 then sql::null else new $P$});
$node->safe_psql('postgres', 'DROP TRIGGER t_ins ON item');
$node->safe_psql('postgres',
	'CREATE TRIGGER t_rej BEFORE INSERT ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION reject_big()');
$node->safe_psql('postgres',
	'INSERT INTO item (id, qty, price) VALUES (3, 999, 1.0)');    # skipped
$node->safe_psql('postgres',
	'INSERT INTO item (id, qty, price) VALUES (4, 7, 1.0)');      # kept
is($node->safe_psql('postgres',
		"SELECT string_agg(id::text, ',' ORDER BY id) FROM item"),
	'1,2,4', 'sql::null from a BEFORE INSERT skipped the row cleanly');
$node->safe_psql('postgres', 'DROP TRIGGER t_rej ON item');

# --- AFTER DELETE: old is the deleted row; SPI runs from the body ---------
$node->safe_psql('postgres', 'CREATE TABLE audit (what text)');
$node->safe_psql('postgres',
	q{CREATE FUNCTION log_del() RETURNS trigger LANGUAGE pg_pureu AS }
	  . q{$P$ sql::exec ("INSERT INTO audit VALUES ($1)", [str (old!"id")]) $P$});
$node->safe_psql('postgres',
	'CREATE TRIGGER t_del AFTER DELETE ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION log_del()');
$node->safe_psql('postgres', 'DELETE FROM item WHERE id = 1');
is($node->safe_psql('postgres', 'SELECT what FROM audit'),
	'1', 'AFTER DELETE saw old and ran an SPI insert; the delete proceeded');
is($node->safe_psql('postgres', 'SELECT count(*) FROM item WHERE id = 1'),
	'0', 'the deleted row is gone (AFTER return value ignored)');

# --- tg describes the event -----------------------------------------------
$node->safe_psql('postgres',
	q{CREATE FUNCTION tg_desc() RETURNS trigger LANGUAGE pg_pureu AS }
	  . q{$P$ insert new ("total" => }
	  . q{(if tg!"op" == "INSERT" && tg!"level" == "ROW" then 1 else 0)) $P$});
$node->safe_psql('postgres',
	'CREATE TRIGGER t_tg BEFORE INSERT ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION tg_desc()');
$node->safe_psql('postgres',
	'INSERT INTO item (id, qty, price) VALUES (5, 1, 1.0)');
is($node->safe_psql('postgres', 'SELECT total FROM item WHERE id = 5'),
	'1', 'tg reports op and level to the body');
$node->safe_psql('postgres', 'DROP TRIGGER t_tg ON item');

# --- SAFETY: bad returns and the escape guard error cleanly, never crash --
# A body returning a non-record non-null value.
$node->safe_psql('postgres',
	q{CREATE FUNCTION ret_int() RETURNS trigger LANGUAGE pg_pureu AS $P$ 42 $P$});
$node->safe_psql('postgres',
	'CREATE TRIGGER t_bad BEFORE INSERT ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION ret_int()');
my ($rc1, $out1, $err1) =
  $node->psql('postgres', 'INSERT INTO item (id) VALUES (6)', on_error_stop => 0);
like($err1, qr/record or sql::null/,
	'a non-record trigger return raises a clean error');
$node->safe_psql('postgres', 'DROP TRIGGER t_bad ON item');

# A body naming a column that does not exist.
$node->safe_psql('postgres',
	q{CREATE FUNCTION ret_badcol() RETURNS trigger LANGUAGE pg_pureu AS }
	  . q{$P$ insert new ("nosuch" => 1) $P$});
$node->safe_psql('postgres',
	'CREATE TRIGGER t_bc BEFORE INSERT ON item FOR EACH ROW '
	  . 'EXECUTE FUNCTION ret_badcol()');
my ($rc2, $out2, $err2) =
  $node->psql('postgres', 'INSERT INTO item (id) VALUES (7)', on_error_stop => 0);
like($err2, qr/no column "nosuch"/,
	'a trigger record naming an unknown column raises a clean error');
$node->safe_psql('postgres', 'DROP TRIGGER t_bc ON item');

# The single-expression escape guard applies to trigger bodies too.
my ($rc3, $out3, $err3) = $node->psql(
	'postgres',
	q{CREATE FUNCTION tg_evil() RETURNS trigger LANGUAGE pg_pureu }
	  . q{AS $P$ new); leaked = 42; (new $P$},
	on_error_stop => 0);
like($err3, qr/single expression/,
	'a trigger body cannot close the wrapper and define a global');

# The backend still works after all the error cases.
is($node->safe_psql('postgres', 'SELECT 1'), '1',
	'the backend survives every trigger error path');

$node->stop('fast');
my $log = slurp_file($node->logfile);
my $crashes = () = $log =~ /was terminated by signal/g;
is($crashes, 0, 'no backend crashed during the trigger tests');

done_testing();
