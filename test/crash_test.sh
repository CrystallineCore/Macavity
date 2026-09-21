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
# shared memory after an unclean exit -- and NOT macavity event state
# reaching another session.  Those sessions never had an event armed; they
# are simply disconnected along with everything else.  The crashed
# connection itself cannot restore itself either: the client must reconnect,
# and the new session starts with an empty event registry, which is what
# step 4 below verifies.
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
#	4. the reconnected session has an empty event registry -- the events
#	   died with the backend
#	5. a committed row written before the crash survives recovery
#	6. precedence crash > error: with both due at the same hit, the backend
#	   dies without the error ever being raised, even though the error
#	   event has the lower ID
#	7. precedence delay > crash: with both due at the same hit, the delay
#	   runs before the crash, even though the crash event has the lower ID
#
# The cluster is crashed three times in all.
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

# Crash recovery takes a moment; retry rather than racing it.
wait_for_recovery() {
	i=0
	while [ "$i" -lt 60 ]; do
		if [ "$(psql_q 'SELECT 1')" = "1" ]; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	fail "cluster did not accept connections again within 60s"
}

# psql reports the lost connection in one of these ways, depending on version.
lost_connection() {
	echo "$1" | grep -qE 'server closed the connection|connection to server was lost|terminated abnormally'
}

echo "macavity crash test -- this WILL crash the target cluster"
echo

# --- sanity ------------------------------------------------------------
version=$(psql_q "SELECT extversion FROM pg_extension WHERE extname = 'macavity'")
case "$version" in
	0.*) echo "1..7  macavity $version found" ;;
	*) fail "macavity is not installed in the target database ($version)" ;;
esac

# --- a durable row to look for after recovery --------------------------
psql_q "DROP TABLE IF EXISTS macavity_crash_survivors;
		CREATE TABLE macavity_crash_survivors (note text);
		INSERT INTO macavity_crash_survivors VALUES ('committed before the crash');" \
	>/dev/null

# --- 1 & 2: crash at occurrence 3, not before --------------------------
# One session: arm executor_start at occurrence 3, then run statements until
# the event fires.  The early ones must produce output and the counter must
# advance as they do; the last one must kill the backend, so psql loses the
# connection.
#
# The counter readings prove the hit is recorded before the action runs:
# each status query is itself a matching hit, so it reports the hit it has
# just caused.  The crashing hit cannot be read back -- the registry lived in
# the backend that just died -- but it is counted by the same code path, in
# the same order, before macavity_execute_action() is ever called.
out=$(psql_script <<'SQL'
SELECT macavity_arm('executor_start', 'crash', 3);
SELECT 'hits=' || hits || ' remaining=' || remaining AS counter FROM macavity_status() WHERE event_id = 1;
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
wait_for_recovery
echo "ok 3  - cluster recovered and accepts connections"

# --- 4: the reconnected session is clean ------------------------------
# The crashed connection is gone for good; this is a brand-new session.  Its
# registry must be empty: macavity events live only in the backend that
# created them, so there is nothing for a new backend to inherit.  Its first
# event gets ID 1 again.
state=$(psql_q "SELECT count(*) FROM macavity_status()")
[ "$state" = "0" ] ||
	fail "reconnected session has stale events: $state"
first_id=$(psql_q "SELECT macavity_arm_error('executor_start', 9999)")
[ "$first_id" = "1" ] ||
	fail "reconnected session did not start IDs at 1: $first_id"
echo "ok 4  - reconnected session has an empty registry, IDs start at 1"

# --- 5: the committed row survived ------------------------------------
note=$(psql_q "SELECT note FROM macavity_crash_survivors")
[ "$note" = "committed before the crash" ] ||
	fail "committed data did not survive crash recovery (got '$note')"
echo "ok 5  - data committed before the crash survived recovery"

psql_q "DROP TABLE macavity_crash_survivors" >/dev/null

# --- 6: crash > error ---------------------------------------------------
# The error event is created first (ID 1), the crash event second (ID 2),
# both due at the next executor_start hit.  Precedence puts crash first, so
# the backend dies and the injected error is never raised.
out=$(psql_script <<'SQL'
SELECT 'ids=' || macavity_arm_error('executor_start') || ',' || macavity_arm_crash('executor_start');
SELECT 'should-not-print' AS marker;
SQL
)
echo "$out" | grep -q 'ids=1,2' || fail "unexpected event IDs: $out"
if echo "$out" | grep -q 'injected error'; then
	fail "the error event ran before the crash event: $out"
fi
lost_connection "$out" || fail "the backend survived its crash event: $out"
echo "ok 6  - crash takes precedence over error, regardless of event_id"
wait_for_recovery

# --- 7: delay > crash ---------------------------------------------------
# The crash event is created first (ID 1), the delay event second (ID 2),
# both due at the next executor_start hit.  Precedence puts delay first, so
# the backend sleeps for the 1 s delay and only then dies.  Without the
# delay the whole script takes a small fraction of a second.
start=$(date +%s%N)
out=$(psql_script <<'SQL'
SELECT 'ids=' || macavity_arm_crash('executor_start') || ',' || macavity_arm_delay('executor_start');
SELECT 'should-not-print' AS marker;
SQL
)
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
echo "$out" | grep -q 'ids=1,2' || fail "unexpected event IDs: $out"
lost_connection "$out" || fail "the backend survived its crash event: $out"
[ "$elapsed_ms" -ge 900 ] ||
	fail "the backend crashed after ${elapsed_ms} ms: the delay did not run first"
echo "ok 7  - delay runs before crash, regardless of event_id (${elapsed_ms} ms)"
wait_for_recovery

echo
echo "# All 7 crash tests passed."
