#!/bin/sh
#
# crash_test.sh -- exercise the macavity "crash" action.
#
# This test is deliberately NOT part of the pg_regress suite.  The crash
# action SIGKILLs its own backend, and PostgreSQL's postmaster responds to
# any unclean backend exit by terminating the remaining backends and running
# crash recovery.  pg_regress cannot survive that, so crash coverage lives
# here instead.
#
# ==> RUN THIS AGAINST A THROWAWAY CLUSTER ONLY.  It will crash the cluster
# ==> you point it at, on purpose, and every other session on that cluster
# ==> will be disconnected.
#
# Usage:
#	test/crash_test.sh [psql connection options]
#
# e.g.	test/crash_test.sh -h /tmp -p 55432 -d contrib_regression
#
# The extension must already be installed (make install) and created
# (CREATE EXTENSION macavity) in the target database.
#
# What it checks:
#	1. the armed backend dies at the fault point
#	2. it dies at the *configured occurrence*, not before
#	3. the cluster recovers and accepts connections again
#	4. a committed row written before the crash survives recovery
#
set -u

PSQL="${PSQL:-psql}"
PSQL_OPTS="$*"

psql_q() {
	# shellcheck disable=SC2086
	$PSQL $PSQL_OPTS -X -q -A -t -v ON_ERROR_STOP=0 -c "$1" 2>&1
}

# Reads a script on stdin.  Each line is sent as its own query, which is
# what we need here: statements batched into a single query message would
# all be lost together when the backend dies, hiding the output of the
# statements that ran before the fault.
psql_script() {
	# shellcheck disable=SC2086
	$PSQL $PSQL_OPTS -X -q -A -t -v ON_ERROR_STOP=0 2>&1
}

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

echo "macavity crash test -- this WILL crash the target cluster"
echo

# --- sanity ------------------------------------------------------------
version=$(psql_q "SELECT extversion FROM pg_extension WHERE extname = 'macavity'")
case "$version" in
	0.*) echo "1..4  macavity $version found" ;;
	*) fail "macavity is not installed in the target database ($version)" ;;
esac

# --- a durable row to look for after recovery --------------------------
psql_q "DROP TABLE IF EXISTS macavity_crash_survivors;
		CREATE TABLE macavity_crash_survivors (note text);
		INSERT INTO macavity_crash_survivors VALUES ('committed before the crash');" \
	>/dev/null

# --- 1 & 2: crash at occurrence 3, not before --------------------------
# One session: arm executor_start at occurrence 3, then run three
# statements.  The first two must produce output; the third must kill the
# backend, so psql loses the connection.
out=$(psql_script <<'SQL'
SELECT macavity_arm('executor_start', 'crash', 3);
SELECT 'event-one' AS marker;
SELECT 'event-two' AS marker;
SELECT 'event-three-should-not-print' AS marker;
SQL
)

echo "$out" | grep -q 'event-one' || fail "statement before the fault did not run"
echo "$out" | grep -q 'event-two' || fail "second statement before the fault did not run"

if echo "$out" | grep -q 'event-three-should-not-print'; then
	fail "the backend survived its crash fault"
fi
echo "ok 1  - backend terminated at the fault point"
echo "ok 2  - earlier occurrences passed through untouched"

# --- 3: the cluster comes back ----------------------------------------
# Crash recovery takes a moment; retry rather than racing it.
i=0
while [ "$i" -lt 60 ]; do
	if [ "$(psql_q 'SELECT 1')" = "1" ]; then
		break
	fi
	i=$((i + 1))
	sleep 1
done
[ "$i" -lt 60 ] || fail "cluster did not accept connections again within 60s"
echo "ok 3  - cluster recovered and accepts connections"

# --- 4: the committed row survived ------------------------------------
note=$(psql_q "SELECT note FROM macavity_crash_survivors")
[ "$note" = "committed before the crash" ] ||
	fail "committed data did not survive crash recovery (got '$note')"
echo "ok 4  - data committed before the crash survived recovery"

psql_q "DROP TABLE macavity_crash_survivors" >/dev/null

echo
echo "# All 4 crash tests passed."
