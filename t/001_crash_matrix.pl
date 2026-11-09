# t/001_crash_matrix.pl -- PostgreSQL's JIT and libpure's LLVM in one backend.
#
# PGDG builds llvmjit against a different LLVM major than libpure links. If
# libpure exported LLVM symbols they would clash and the backend would crash
# at exit -- after every query had already succeeded. So a case counts only
# when its own queries returned the right answer (proving Pure actually ran),
# and a crash is read from the server log ("terminated by signal"), never from
# a client exit code. See DESIGN.md section 5 and AGENTS.md rule 2.
#
# The matrix runs PostgreSQL JIT and a Pure function in the same backend in
# both orders, with jit forced on for every statement.
#
# This test is only a real coexistence check where PostgreSQL's llvmjit is
# installed (then jit=on actually LLVM-compiles, and the libpure/llvmjit
# symbol clash would fire). Where llvmjit is absent PostgreSQL no-ops JIT and
# this is a smoke test. The meaningful run is on a JIT-enabled server (the
# dev box and the Nix/BSD runs keep llvmjit installed).
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('crashmatrix');
$node->init;
$node->append_conf(
	'postgresql.conf', qq{
jit = on
jit_above_cost = 0
jit_inline_above_cost = 0
jit_optimize_above_cost = 0
pg_pure.using = 'math'
});
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');
$node->safe_psql('postgres',
	q{CREATE FUNCTION pm(x int, y int) RETURNS int LANGUAGE pg_pureu AS 'x*y+1'});

# A query heavy enough that PostgreSQL JIT-compiles it, with a known answer.
my $jit_sql  = 'SELECT sum(g)::text FROM generate_series(1,100000) g';
my $jit_want = '5000050000';
my $pure_sql = 'SELECT pm(2,3)::text';
my $pure_want = '7';

# Each case runs in a fresh backend (a new psql session), so the clash, if
# any, fires when that backend exits.
sub case
{
	my ($name, @steps) = @_;
	my $ok = 1;
	# Run all steps in ONE session so JIT and Pure share a backend.
	my $script = join(";\n", map { $_->[0] } @steps);
	my ($rc, $out, $err) = $node->psql('postgres', $script);
	my @lines = split /\n/, $out;
	for my $i (0 .. $#steps)
	{
		my $got  = defined $lines[$i] ? $lines[$i] : '';
		my $want = $steps[$i]->[1];
		$ok = 0 if $got ne $want;
	}
	ok($ok, "$name: every query returned the right answer (Pure ran)");
	return;
}

# JIT first, then Pure.
case('jit-then-pure', [ $jit_sql, $jit_want ], [ $pure_sql, $pure_want ]);
# Pure first, then JIT.
case('pure-then-jit', [ $pure_sql, $pure_want ], [ $jit_sql, $jit_want ]);
# Interleaved, several rounds, one backend.
case(
	'interleaved',
	[ $pure_sql, $pure_want ],
	[ $jit_sql,  $jit_want ],
	[ $pure_sql, $pure_want ],
	[ $jit_sql,  $jit_want ]);

$node->stop('fast');

# The verdict: scan the log for any signal-termination across the whole run.
my $log = slurp_file($node->logfile);
my $crashes = () = $log =~ /was terminated by signal|terminating connection because of crash/g;
is($crashes, 0, 'no backend was terminated by a signal (JIT + Pure coexist)');

done_testing();
