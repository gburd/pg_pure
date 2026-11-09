#!/bin/sh
# ci/gate.sh -- the full local test gate for pg_pure: the regression suites
# (pg_pureu, pg_pure) and the TAP suite (t/*.pl: the JIT+Pure crash matrix,
# cancel/terminate, concurrency, and bounded-memory checks). Every new TAP
# test is added here (AGENTS.md).
#
# Usage:
#   ci/gate.sh <pg_version>          e.g. ci/gate.sh 18
# Environment:
#   PURE_PREFIX   prefix libpure (+ the vetted modules) is installed under
#                 (default: $HOME/pure-inst)
#   PG_BIN        PostgreSQL bin dir (default: /usr/lib/postgresql/<v>/bin)
#   PG_PURE_USING modules to pre-load/allow-list (default: 'math gsl::linalg')
#
# A crash is read from the server log ("terminated by signal"), never from a
# client exit code -- the JIT/Pure clash fires at backend exit, after every
# query has already succeeded (AGENTS.md rule 2, DESIGN.md section 5).
set -eu

V="${1:?usage: ci/gate.sh <pg_version>}"
PURE_PREFIX="${PURE_PREFIX:-$HOME/pure-inst}"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/$V/bin}"
PG_PURE_USING="${PG_PURE_USING:-math gsl::linalg}"
PG_CONFIG="$PG_BIN/pg_config"
PGXS_PERL="$($PG_CONFIG --pkglibdir)/pgxs/src/test/perl"
PG_REGRESS="$($PG_CONFIG --pkglibdir)/pgxs/src/test/regress/pg_regress"

cd "$(dirname "$0")/.."

echo "=== build + install (PG $V, libpure $PURE_PREFIX) ==="
make -s clean >/dev/null 2>&1 || true
make -s PG_CONFIG="$PG_CONFIG" PURE_PREFIX="$PURE_PREFIX"
make -s check-ascii
sudo make -s install PG_CONFIG="$PG_CONFIG" PURE_PREFIX="$PURE_PREFIX" >/dev/null

echo "=== regression suites (jit=on, both languages) ==="
DD="$(mktemp -d)/data"
"$PG_BIN/initdb" -A trust -U postgres -D "$DD" >/dev/null
{
	echo "unix_socket_directories='/tmp'"
	echo "port=5999"
	echo "jit=on"
	echo "jit_above_cost=0"
	echo "pg_pure.using='$PG_PURE_USING'"
} >> "$DD/postgresql.conf"
PURELIB="$PURE_PREFIX/lib/pure" "$PG_BIN/pg_ctl" -D "$DD" -l "$DD/log" -w start >/dev/null
rc=0
make -s installcheck PG_CONFIG="$PG_CONFIG" PGHOST=/tmp PGPORT=5999 PGUSER=postgres || rc=$?
"$PG_BIN/pg_ctl" -D "$DD" -m fast stop >/dev/null || true
if grep -q "terminated by signal" "$DD/log"; then
	echo "FAIL: a backend crashed during the regression suite"
	grep "terminated by signal" "$DD/log"
	exit 1
fi
[ "$rc" -eq 0 ] || { echo "FAIL: regression diffs"; cat regression.diffs 2>/dev/null || true; exit "$rc"; }

echo "=== TAP suite (t/*.pl) ==="
find tmp_check -mindepth 1 -delete 2>/dev/null || true
rmdir tmp_check 2>/dev/null || true
PERL5LIB="$PGXS_PERL" \
	PATH="$PG_BIN:$PATH" \
	PG_REGRESS="$PG_REGRESS" \
	PURELIB="$PURE_PREFIX/lib/pure" \
	LD_LIBRARY_PATH="$PURE_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	prove t/*.pl

echo "=== gate PASSED (PG $V) ==="
