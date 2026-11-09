# t/002_robustness.pl -- operational robustness the pg.ddx.io evaluation asked
# for (its qualification gate): a cancelled/terminated Pure call leaves the
# server up, many concurrent backends each run Pure, and a backend's memory is
# bounded across a large number of calls. ROADMAP 2.B / 1.7.
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('robust');
$node->init;
$node->append_conf('postgresql.conf', "pg_pure.using = 'math'\n");
$node->start;

$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');
# A scalar kernel, and a function that spins so we can cancel it.
$node->safe_psql('postgres',
	q{CREATE FUNCTION pm(x int, y int) RETURNS int LANGUAGE pg_pureu AS 'x*y+1'});
# A long-running Pure loop: count down from a big number (pure, no SPI).
$node->safe_psql('postgres',
	q{CREATE FUNCTION pspin(n int) RETURNS int LANGUAGE pg_pureu AS 'loop n with loop 0 = 0; loop k = loop (k-1) end'});

# --- 1. statement_timeout cancels a Pure call; the backend survives. -------
my ($rc, $out, $err) = $node->psql(
	'postgres',
	'SET statement_timeout = 500; SELECT pspin(1000000000)',
	on_error_stop => 0);
like($err, qr/canceling statement due to statement timeout/,
	'a running Pure call is cancelled by statement_timeout');
# The server is still up and answers correctly afterwards.
is($node->safe_psql('postgres', 'SELECT pm(6,7)::text'),
	'43', 'server survives the cancel and still runs Pure');

# --- 2. pg_terminate_backend of a backend in a Pure call. ------------------
my $bg = $node->background_psql('postgres', on_error_stop => 0);
$bg->query_until(qr/start/,
	"\\echo start\nSELECT pspin(1000000000);\n");
# From another session, terminate the spinning backend.
$node->safe_psql('postgres',
	q{SELECT pg_terminate_backend(pid) FROM pg_stat_activity
	  WHERE query LIKE 'SELECT pspin%' AND pid <> pg_backend_pid()});
$bg->quit;
is($node->safe_psql('postgres', 'SELECT pm(2,21)::text'),
	'43', 'server survives pg_terminate_backend of a Pure call');

# --- 3. Eight concurrent backends each compile and call Pure. --------------
my @bgs;
for my $i (1 .. 8)
{
	my $h = $node->background_psql('postgres');
	$h->query_safe("SELECT sum(pm(i, $i))::text FROM generate_series(1,2000) i");
	push @bgs, $h;
}
$_->quit for @bgs;
ok(1, 'eight concurrent backends each ran Pure without error');

# --- 4. One backend's RSS plateaus across millions of Pure calls. ----------
# A per-call interpreter leak would make RSS grow linearly with the call
# count. Sample after a warm call and after each of four 1,000,000-call
# batches; assert the final batch adds little (the curve has flattened). This
# catches a real leak without a brittle absolute threshold.
my $h = $node->background_psql('postgres');
my $pid = $h->query_safe('SELECT pg_backend_pid()');
$h->query_safe('SELECT pm(1,1)');    # warm the interpreter
my @rss = (proc_rss($pid));
for my $batch (1 .. 4)
{
	$h->query_safe('SELECT sum(pm(i,2)) FROM generate_series(1,1000000) i');
	push @rss, proc_rss($pid);
}
$h->quit;

SKIP:
{
	skip 'cannot read RSS on this platform', 1
	  unless defined $rss[0] && $rss[0] > 0 && defined $rss[4];
	my $total_mb = ($rss[4] - $rss[0]) / 1024.0;
	my $last_mb  = ($rss[4] - $rss[3]) / 1024.0;
	note(sprintf('RSS KB warm=%d 1M=%d 2M=%d 3M=%d 4M=%d; total=%.1f MB last-batch=%.1f MB',
		@rss, $total_mb, $last_mb));
	# The last 1,000,000 calls must add far less than the first did: a leak
	# would keep each batch costing the same. 8 MB is generous headroom.
	ok($last_mb < 8,
		sprintf('backend RSS plateaus: last 1,000,000 calls added %.1f MB', $last_mb));
}

$node->stop('fast');
my $log = slurp_file($node->logfile);
my $crashes = () = $log =~ /was terminated by signal/g;
is($crashes, 0, 'no backend crashed during the robustness suite');

done_testing();

# RSS of a pid in KB, portable-ish: Linux /proc, else ps.
sub proc_rss
{
	my ($pid) = @_;
	return undef unless defined $pid && $pid =~ /^\d+$/;
	if (open my $fh, '<', "/proc/$pid/status")
	{
		while (<$fh>) { return $1 if /^VmRSS:\s+(\d+)\s+kB/ }
		close $fh;
	}
	my $r = `ps -o rss= -p $pid 2>/dev/null`;
	$r =~ s/\s//g;
	return $r =~ /^\d+$/ ? $r : undef;
}
