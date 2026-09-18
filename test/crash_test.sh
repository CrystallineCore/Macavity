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
# Note on what that disconnection means.  Other clients may see
#
#	terminating connection because of crash of another server process
#
# That is PostgreSQL's own crash containment -- the postmaster protecting
# shared memory after an unclean exit -- and NOT macavity fault state
# reaching another session.  Those sessions never had a fault armed; they
# are simply disconnected along with everything else.  The crashed
# connection itself cannot restore itself either: the client must reconnect,
# and the new session starts with nothing armed, which is what step 4 below
# verifies.
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
#	2. it dies at the *configured occurrence*, not before, and the hits
#	   counter advances on the way there
#	3. the cluster recovers and accepts connections again
#	4. the reconnected session has armed = false and no stale fault
#	   configuration -- the state died with the backend
#	5. a committed row written before the crash survives recovery
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
	0.*) echo "1..5  macavity $version found" ;;
	*) fail "macavity is not installed in the target database ($version)" ;;
esac

# --- a durable row to look for after recovery --------------------------
psql_q "DROP TABLE IF EXISTS macavity_crash_survivors;
		CREATE TABLE macavity_crash_survivors (note text);
		INSERT INTO macavity_crash_survivors VALUES ('committed before the crash');" \
	>/dev/null

# --- 1 & 2: crash at occurrence 3, not before --------------------------
# One session: arm executor_start at occurrence 3, then run statements until
# the fault fires.  The early ones must produce output and the counter must
# advance as they do; the last one must kill the backend, so psql loses the
# connection.
#
# The counter readings prove the hit is recorded before the action runs:
# each status query is itself a matching event, so it reports the hit it has
# just caused.  The crashing hit cannot be read back -- the state lived in
# the backend that just died -- but it is counted by the same code path, in
# the same order, before macavity_execute_action() is ever called.
out=$(psql_script <<'SQL'
SELECT macavity_arm('executor_start', 'crash', 3);
SELECT 'hits=' || hits || ' remaining=' || remaining AS counter FROM macavity_status();
SELECT 'event-two' AS marker;
SELECT 'event-three-should-not-print' AS marker;
SQL
)

echo "$out" | grep -q 'hits=1 remaining=2' ||
	fail "counter did not advance on the first matching hit: $out"
echo "$out" | grep -q 'event-two' || fail "statement before the fault did not run"

if echo "$out" | grep -q 'event-three-should-not-print'; then
	fail "the backend survived its crash fault"
fi
echo "ok 1  - backend terminated at the fault point"
echo "ok 2  - earlier hits counted, and passed through untouched"

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

# --- 4: the reconnected session is clean ------------------------------
# The crashed connection is gone for good; this is a brand-new session.  Its
# fault state must be empty: macavity state lives only in the backend that
# armed it, so there is nothing for a new backend to inherit.
# Note: string concatenation renders the boolean as 'false', not psql's 'f'.
state=$(psql_q "SELECT armed || ' ' || coalesce(point, 'none') || ' ' ||
				coalesce(hits::text, 'none') FROM macavity_status()")
[ "$state" = "false none none" ] ||
	fail "reconnected session has stale fault state: $state"
echo "ok 4  - reconnected session has armed = false and no stale configuration"

# --- 5: the committed row survived ------------------------------------
note=$(psql_q "SELECT note FROM macavity_crash_survivors")
[ "$note" = "committed before the crash" ] ||
	fail "committed data did not survive crash recovery (got '$note')"
echo "ok 5  - data committed before the crash survived recovery"

psql_q "DROP TABLE macavity_crash_survivors" >/dev/null

echo
echo "# All 5 crash tests passed."
