# t/004_preload.pl -- behaviour of shared_preload_libraries='pg_pure'
# (ROADMAP 1.6, DESIGN.md section 3).
#
# _PG_init warms both interpreters in the postmaster when preloaded, so the
# postmaster pays the one-time LLVM codegen at startup. This test confirms the
# preloaded server starts, warms without error, and serves Pure correctly from
# forked backends with no crash.
#
# It also MEASURES, and records as diagnostics, the first-call cost of a fresh
# backend with and without preload. As of this writing the warmed interpreter
# state is NOT effectively inherited across fork: a forked backend re-pays the
# per-function codegen on its first call, so preload does not lower first-call
# latency (it only front-loads the cost into postmaster startup). The test
# does not assert a speedup it cannot currently deliver; it asserts the
# correctness and no-crash properties and prints the measured gap so a future
# change that makes warm state fork-inheritable will show up here.
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use Time::HiRes qw(time);

# first_call_ms($node): wall time of the FIRST pg_pure call in a freshly
# forked backend (each safe_psql is a new backend), min of a few tries.
sub first_call_ms
{
	my ($node) = @_;
	my $best;
	for (1 .. 5)
	{
		my $t0 = time;
		my $out = $node->safe_psql('postgres', 'SELECT pm(6,7)');
		my $ms = (time - $t0) * 1000.0;
		die "wrong answer: $out" unless $out eq '43';
		$best = $ms if !defined $best || $ms < $best;
	}
	return $best;
}

sub setup
{
	my ($node) = @_;
	$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');
	$node->safe_psql('postgres',
		q{CREATE FUNCTION pm(x int, y int) RETURNS int LANGUAGE pg_pureu AS 'x*y+1'});
}

# --- without preload ------------------------------------------------------
my $cold = PostgreSQL::Test::Cluster->new('noprel');
$cold->init;
$cold->append_conf('postgresql.conf', "pg_pure.using = 'math'\n");
$cold->start;
setup($cold);
my $cold_ms = first_call_ms($cold);
note(sprintf('first call without preload: %.0f ms', $cold_ms));
$cold->stop('fast');

# --- with preload ---------------------------------------------------------
# A preloaded start pays the warm-up (both interpreters) in the postmaster, so
# startup is seconds, not milliseconds. That the server comes up at all is the
# evidence the warm-up ran without error.
my $warm = PostgreSQL::Test::Cluster->new('prel');
$warm->init;
$warm->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_pure'\npg_pure.using = 'math'\n");
$warm->start;
ok(1, 'server starts with shared_preload_libraries and the warm-up runs');
setup($warm);
my $warm_ms = first_call_ms($warm);
note(sprintf('first call with preload: %.0f ms', $warm_ms));
note(sprintf('preload first-call delta: %+.0f ms (negative means preload helped)',
	$warm_ms - $cold_ms));

# Correctness, not latency: a preloaded backend runs Pure correctly, and a
# later backend does too (state inherited enough to be usable).
is($warm->safe_psql('postgres', 'SELECT pm(100,2)'), '201',
	'a backend under preload runs Pure correctly');
is($warm->safe_psql('postgres', 'SELECT sum(pm(i,2)) FROM generate_series(1,1000) i'),
	'1002000', 'many calls under preload are correct');

$warm->stop('fast');
my $log = slurp_file($warm->logfile);
my $crashes = () = $log =~ /was terminated by signal/g;
is($crashes, 0, 'no backend crashed under shared_preload_libraries');

done_testing();
