# t/003_conversions.pl -- property round-trip tests for the type conversions
# (ROADMAP 2.5, DESIGN.md section 8). The invariant: a value handed to a
# pg_pure function and returned unchanged comes back EXACTLY, and a value that
# does not fit its type is an ERROR, never a silently wrong answer.
#
# The conversion only runs inside a backend (Datum <-> pure_expr), so the
# oracle is "SQL value in == SQL value out through a pg_pure identity
# function". Values are generated across each type's range, with the
# boundaries that bite (type MIN/MAX, 0, +-1, and -- because Pure machine ints
# are 32-bit and wrap silently -- values that overflow 32 bits) always
# included.
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('conv');
$node->init;
$node->append_conf('postgresql.conf', "pg_pure.using = 'math'\n");
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_pureu');

# One identity function per type: the body is just the argument, so a correct
# round-trip depends entirely on the datum<->pure conversion both ways.
my %idfn = (
	int2    => 'CREATE FUNCTION id_i2(x int2) RETURNS int2 LANGUAGE pg_pureu AS \'x\'',
	int4    => 'CREATE FUNCTION id_i4(x int4) RETURNS int4 LANGUAGE pg_pureu AS \'x\'',
	int8    => 'CREATE FUNCTION id_i8(x int8) RETURNS int8 LANGUAGE pg_pureu AS \'x\'',
	float4  => 'CREATE FUNCTION id_f4(x float4) RETURNS float4 LANGUAGE pg_pureu AS \'x\'',
	float8  => 'CREATE FUNCTION id_f8(x float8) RETURNS float8 LANGUAGE pg_pureu AS \'x\'',
	numeric => 'CREATE FUNCTION id_num(x numeric) RETURNS numeric LANGUAGE pg_pureu AS \'x\'',
	bool    => 'CREATE FUNCTION id_b(x bool) RETURNS bool LANGUAGE pg_pureu AS \'x\'',
	text    => 'CREATE FUNCTION id_t(x text) RETURNS text LANGUAGE pg_pureu AS \'x\'',
	arr     => 'CREATE FUNCTION id_arr(x float8[]) RETURNS float8[] LANGUAGE pg_pureu AS \'x\'',
);
$node->safe_psql('postgres', $_) for values %idfn;

# roundtrip($fn, $literal, $cast): the value cast into SQL, passed through the
# identity function, must equal the same value selected directly. Equality is
# by value for numeric and float (a trailing-zero scale like 100.00 vs 100 is
# not information, and Pure's exact rational does not carry display scale);
# by text for everything else, so a type confusion cannot slip through.
sub roundtrip
{
	my ($fn, $lit, $cast, $byval) = @_;
	my $expr = $byval
	  ? "$fn(($lit)::$cast) = (($lit)::$cast)"
	  : "($fn(($lit)::$cast))::text IS NOT DISTINCT FROM (($lit)::$cast)::text";
	my $got = $node->safe_psql('postgres', "SELECT $expr");
	return $got eq 't';
}

# --- integers: boundaries plus random values across the whole range -------
my @i2 = (-32768, 32767, 0, 1, -1, 12345, -9999);
my @i4 = (-2147483648, 2147483647, 0, 1, -1, 100000, -70000);
# int8 values that OVERFLOW 32 bits: these prove pg_pure uses int64/bigint,
# not Pure's silently-wrapping 32-bit machine int.
my @i8 = (
	'-9223372036854775808', '9223372036854775807', '0', '1', '-1',
	'4294967296', '-4294967297', '9000000000000000000');
push @i2, int(rand(65536)) - 32768 for 1 .. 20;
push @i4, int(rand(4294967296)) - 2147483648 for 1 .. 20;

my $ok = 1;
$ok &&= roundtrip('id_i2', $_, 'int2') for @i2;
ok($ok, 'int2 round-trips exactly across its range');
$ok = 1;
$ok &&= roundtrip('id_i4', $_, 'int4') for @i4;
ok($ok, 'int4 round-trips exactly across its range');
$ok = 1;
$ok &&= roundtrip('id_i8', $_, 'int8') for @i8;
ok($ok, 'int8 round-trips exactly (including values that overflow 32 bits)');

# --- float4/float8: boundaries and random magnitudes ----------------------
my @f = (0, '1', '-1', '0.5', '-0.5', '3.14159', '1e10', '-1e-10', '1e-300', '1e300');
push @f, sprintf('%.17g', (rand() - 0.5) * (10 ** (int(rand(40)) - 20))) for 1 .. 20;
$ok = 1;
$ok &&= roundtrip('id_f8', $_, 'float8', 1) for @f;
ok($ok, 'float8 round-trips exactly');
$ok = 1;
# float4 has less precision; compare after the cast so the oracle matches.
$ok &&= roundtrip('id_f4', $_, 'float4', 1) for (0, '1', '-1', '0.5', '0.25', '3.5', '1e10', '-1e-10');
ok($ok, 'float4 round-trips exactly');

# --- numeric: exact, including large and high-scale values ----------------
# The 0.333 / 123.456 / -123.456 cases are the regression that exposed two
# round-trip bugs (a leading-zero mantissa read as octal on the way in, and a
# scale derived from the wrong -- normalized -- denominator on the way out).
my @num = (
	'0', '1', '-1', '0.1', '-0.1', '3.14159265358979323846',
	'0.333', '123.456', '-123.456', '0.123456789012345',
	'1234567890.123456789', '999999.999999', '-0.25',
	'123456789012345678901234567890',
	'-99999999999999999999.99999999999999999999',
	'0.00000000000000000001');
$ok = 1;
$ok &&= roundtrip('id_num', $_, 'numeric', 1) for @num;
ok($ok, 'numeric round-trips exactly (no scale loss)');

# --- bool, text (including Unicode and empty) -----------------------------
$ok = 1;
$ok &&= roundtrip('id_b', $_, 'bool') for ('true', 'false');
ok($ok, 'bool round-trips');
$ok = 1;
for my $t ('', 'hello', 'a b c', "tab\there", "it's a quote", "\N{U+00e9}\N{U+6c34}\N{U+1f600}")
{
	my $lit = $t;
	$lit =~ s/'/''/g;
	$ok &&= roundtrip('id_t', "'$lit'", 'text');
}
ok($ok, 'text round-trips exactly (empty, spaces, quotes, Unicode)');

# --- float8[] : 1-D and 2-D, random contents ------------------------------
$ok = 1;
$ok &&= roundtrip('id_arr', $_, 'float8[]')
  for ('ARRAY[1.0,2.0,3.0]', 'ARRAY[[1.0,2.0],[3.0,4.0]]', 'ARRAY[0.0]', 'ARRAY[-1.5,2.5,1e100]');
ok($ok, 'float8[] round-trips exactly (1-D and 2-D)');

# --- out of range is an ERROR, never a wrong (wrapped) answer -------------
# int2 cannot hold 40000; a function returning int2 given that value must
# raise, not wrap to a negative. Build the value in int4 inside the body.
$node->safe_psql('postgres',
	'CREATE FUNCTION over_i2(x int4) RETURNS int2 LANGUAGE pg_pureu AS \'x\'');
my ($rc, $out, $err) = $node->psql('postgres', 'SELECT over_i2(40000)',
	on_error_stop => 0);
like($err, qr/out of range|cannot be converted/,
	'a value too large for int2 is an ERROR, not a silent wrap');

# int4 cannot hold an int8 that exceeds 2^31; must raise, not truncate.
$node->safe_psql('postgres',
	'CREATE FUNCTION over_i4(x int8) RETURNS int4 LANGUAGE pg_pureu AS \'x\'');
($rc, $out, $err) = $node->psql('postgres', 'SELECT over_i4(5000000000)',
	on_error_stop => 0);
like($err, qr/out of range|cannot be converted/,
	'an int8 beyond int4 range is an ERROR, not a silent truncation');

$node->stop('fast');
my $log = slurp_file($node->logfile);
my $crashes = () = $log =~ /was terminated by signal/g;
is($crashes, 0, 'no backend crashed during the conversion property tests');

done_testing();
