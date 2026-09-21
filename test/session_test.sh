#!/bin/sh
#
# session_test.sh -- check that the event registry is session-local.
#
# pg_regress runs each test file in a single session, so it cannot show that
# session A's events leave session B alone.  This script uses separate psql
# connections -- two of them concurrently -- to demonstrate it.
#
# Nothing here crashes anything: only the 'error' action is used, and it is
# safe to run against any test cluster.
#
# Scope note.  What is demonstrated here is that macavity's own event
# registry never crosses sessions: it lives in backend-local memory, so
# session B cannot inherit, observe, renumber or be fired by session A's
# events.
#
# That is a separate matter from what PostgreSQL does after a backend
# crashes.  When the 'crash' action kills a backend, the postmaster
# terminates the other backends as well and runs crash recovery, and those
# clients see "terminating connection because of crash of another server
# process".  Those sessions are disconnected by the server's crash
# containment; they did not inherit a macavity event, and none of them ever
# had one armed.  See test/crash_test.sh.
#
# Usage:
#	test/session_test.sh [psql connection options]
#
# e.g.	test/session_test.sh -h /tmp -p 55432 -d contrib_regression
#
set -u

PSQL="${PSQL:-psql}"
PSQL_OPTS="$*"

psql_q() {
	# shellcheck disable=SC2086
	$PSQL $PSQL_OPTS -X -q -A -t -v ON_ERROR_STOP=0 -c "$1" 2>&1
}

psql_script() {
	# shellcheck disable=SC2086
	$PSQL $PSQL_OPTS -X -q -A -t -v ON_ERROR_STOP=0 2>&1
}

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

echo "1..5  macavity session isolation"

# --- 1: an armed event does not exist for another session --------------
# Session A arms an event and, in the same connection, proves it fired.
a_out=$(psql_script <<'SQL'
SELECT macavity_arm('executor_start', 'error');
SELECT 'session-a-statement' AS marker;
SQL
)
echo "$a_out" | grep -q 'injected error at fault point "executor_start"' ||
	fail "session A did not see its own event fire (got: $a_out)"
echo "ok 1  - session A's event fires in session A"

# --- 2: a fresh session sees no events --------------------------------
b_out=$(psql_script <<'SQL'
SELECT count(*) FROM macavity_status();
SELECT 'session-b-statement' AS marker;
SQL
)
echo "$b_out" | grep -q '^0$' || fail "session B reports events: $b_out"
echo "$b_out" | grep -q 'session-b-statement' ||
	fail "session B's statement did not run: $b_out"
echo "ok 2  - session B is unaffected and has an empty registry"

# --- 3 & 4: two live sessions, two independent registries --------------
# Session A creates two events and then holds its connection open while
# session B works.  B's first event must get ID 1 (IDs are per backend),
# B must see only its own event, and B's disarm-all and reset must leave
# A's events untouched.
a_out_file=$(mktemp)
trap 'rm -f "$a_out_file"' EXIT
psql_script >"$a_out_file" <<'SQL' &
SELECT 'a-ids=' || macavity_arm_error('executor_start', 9999) || ',' ||
	   macavity_arm_error('before_commit', 9999) AS ids;
SELECT pg_sleep(4);
SELECT 'a-after=' || string_agg(event_id || ':' || state, ',' ORDER BY event_id)
  FROM macavity_status();
SQL
a_pid=$!
sleep 1

b_out=$(psql_script <<'SQL'
SELECT 'b-id=' || macavity_arm_error('executor_start', 9999);
SELECT 'b-rows=' || count(*) FROM macavity_status();
SELECT 'b-disarm=' || macavity_disarm();
SELECT 'b-reset=' || macavity_reset();
SQL
)
wait "$a_pid"
a_out=$(cat "$a_out_file")

echo "$a_out" | grep -q 'a-ids=1,2' || fail "session A got unexpected IDs: $a_out"
echo "$b_out" | grep -q 'b-id=1' ||
	fail "session B's first event did not get ID 1: $b_out"
echo "$b_out" | grep -q 'b-rows=1' ||
	fail "session B sees events that are not its own: $b_out"
echo "ok 3  - concurrent sessions allocate event IDs independently"

echo "$b_out" | grep -q 'b-disarm=true' || fail "session B disarm: $b_out"
echo "$b_out" | grep -q 'b-reset=1' || fail "session B reset: $b_out"
echo "$a_out" | grep -q 'a-after=1:armed,2:armed' ||
	fail "session B's disarm/reset reached session A: $a_out"
echo "ok 4  - disarm and reset in session B leave session A's events armed"

# --- 5: state does not survive the session ----------------------------
# A session creates an event at a high occurrence and disconnects without
# disarming; a later session must still start with an empty registry.
psql_q "SELECT macavity_arm('executor_start', 'error', 9999)" >/dev/null
c_out=$(psql_q "SELECT count(*) FROM macavity_status()")
[ "$c_out" = "0" ] ||
	fail "a new session inherited events from a previous one: $c_out"
echo "ok 5  - the registry does not outlive the session that created it"

echo
echo "# All 5 session-isolation tests passed."
