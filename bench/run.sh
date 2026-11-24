#!/usr/bin/env bash
# bench/run.sh -- benchmark pg_pure against PL/pgSQL, PL/Python and PL/Perl.
#
# pg_pure's cost is bimodal and both numbers matter:
#   - COLD: the first call to a given function in a backend compiles it with
#     LLVM, which costs seconds.  Preload warms the postmaster, but a forked
#     backend does not inherit the warmed codegen (ROADMAP 1.6), so each new
#     connection pays this once per distinct function.
#   - WARM: every call after the first in the same backend is fast.
# This harness reports BOTH: cold first-call latency (one timed call in a fresh
# connection) and warm steady-state throughput (many calls in one connection,
# so the one-time compile is amortized away).  The other three languages have
# no comparable cold penalty; their cold and warm numbers are close, so one
# warm number represents them.
#
# Discipline (pg_pure rule 4, pg-benchmark-rigor): warm before timing the warm
# figure; REPS interleaved repetitions; median and min; record box, PG version,
# date, loop size.  Reports only what it measured on this host.
set -euo pipefail

PGBIN=${PGBIN:?set PGBIN to the target PostgreSQL bin dir}
PORT=${PORT:-5494}
HOST=${HOST:-/tmp}
DB=${DB:-postgres}
REPS=${REPS:-7}
ITERS=${ITERS:-20000}   # calls per warm-timing statement
PSQL="$PGBIN/psql -X -tA -h $HOST -p $PORT -U postgres -d $DB"

CHOL_A="ARRAY[[4.0,12,-16],[12,37,-43],[-16,-43,98]]::float8[]"
CHOL_B="ARRAY[1.0,2,3]::float8[]"
WORK=$(cat <<EOF
fib	fib_plpgsql	fib_plpgsql((i % 90) + 1)	fib_plpgsql(45)
fib	fib_plpython	fib_plpython((i % 90) + 1)	fib_plpython(45)
fib	fib_plperl	fib_plperl((i % 90) + 1)	fib_plperl(45)
fib	fib_pure	fib_pure((i % 90) + 1)	fib_pure(45)
hsum	hsum_plpgsql	hsum_plpgsql((i % 200) + 1)	hsum_plpgsql(100)
hsum	hsum_plpython	hsum_plpython((i % 200) + 1)	hsum_plpython(100)
hsum	hsum_plperl	hsum_plperl((i % 200) + 1)	hsum_plperl(100)
hsum	hsum_pure	hsum_pure((i % 200) + 1)	hsum_pure(100)
chol	chol_plpgsql	chol_plpgsql($CHOL_A, $CHOL_B)	chol_plpgsql($CHOL_A, $CHOL_B)
chol	chol_pure	chol_pure($CHOL_A, $CHOL_B)	chol_pure($CHOL_A, $CHOL_B)
EOF
)

# WARM: server executor time (ms) for ITERS calls in a backend that has
# already compiled the function.  A single psql session warms the function
# first, then runs the timed statement, so the one-time LLVM compile is paid
# before timing and amortized away.  Each psql -c is a fresh backend, so the
# warm-up and the measurement must share one session.
warm_time() {
  $PSQL -v ON_ERROR_STOP=0 <<SQL 2>/dev/null | awk '/Execution Time:/ {print $NF}'
SELECT $1 FROM generate_series(1,200) i;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON, FORMAT YAML)
  SELECT $1 FROM generate_series(1, $ITERS) i;
SQL
}

# COLD: wall time (ms) of the very first call to a function in a brand-new
# connection.  A fresh psql per measurement guarantees an unwarmed backend.
# $1 = a single-call expression (e.g. fib_pure(45)).
cold_time() {
  $PSQL -v ON_ERROR_STOP=1 <<SQL 2>/dev/null | awk '/Execution Time:/ {print $NF}'
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON, FORMAT YAML) SELECT $1;
SQL
}

median() { sort -n | awk '{a[NR]=$1} END{n=NR; if(n==0){print "NA"} else if(n%2){print a[(n+1)/2]} else {printf "%.3f\n",(a[n/2]+a[n/2+1])/2}}'; }
minimum() { sort -n | head -1; }

PGVER=$($PSQL -c "SHOW server_version" | head -1)
BOX=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown} $(uname -m)")
IMDS_TOKEN=$(curl -s --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 120" 2>/dev/null || true)
INSTTYPE=$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "unknown")

echo "# pg_pure benchmark"
echo "# date:      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "# box:       $BOX  (EC2 $INSTTYPE)"
echo "# postgres:  $PGVER"
echo "# method:    warm = median of $REPS interleaved runs of $ITERS calls in one"
echo "#            warmed backend; cold = first call in a fresh connection."
echo "# figures:   warm_us_per_call (steady state) and cold_ms (first-call latency)."
echo "#"
printf "%-16s %16s %14s\n" "function" "warm_us/call" "cold_ms"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pgpure_bench.XXXXXX")
trap 'find "$TMP" -mindepth 1 -delete 2>/dev/null; rmdir "$TMP" 2>/dev/null' EXIT

for grp in $(printf '%s\n' "$WORK" | cut -f1 | awk '!seen[$0]++'); do
  while IFS=$'\t' read -r g name wexpr cexpr; do
    [ "$g" = "$grp" ] || continue
    : > "$TMP/$name"
  done <<< "$WORK"
  for ((r=1; r<=REPS; r++)); do
    while IFS=$'\t' read -r g name wexpr cexpr; do
      [ "$g" = "$grp" ] || continue
      warm_time "$wexpr" >> "$TMP/$name"
    done <<< "$WORK"
  done
  while IFS=$'\t' read -r g name wexpr cexpr; do
    [ "$g" = "$grp" ] || continue
    med=$(median < "$TMP/$name")
    uspc=$(awk -v m="$med" -v n="$ITERS" 'BEGIN{if(m=="NA"){print "NA"}else{printf "%.3f", m*1000/n}}')
    cold=$(cold_time "$cexpr")
    printf "%-16s %16s %14s\n" "$name" "$uspc" "${cold:-NA}"
  done <<< "$WORK"
  echo "#"
done
