#!/bin/sh
#
# session_test.sh -- check that fault configuration is session-local.
#
# pg_regress runs each test file in a single session, so it cannot show that
# session A's armed fault leaves session B alone.  This script uses two
# separate psql connections to demonstrate it.
#
# Nothing here crashes anything: only the 'error' action is used, and it is
# safe to run against any test cluster.
#
# Scope note.  What is demonstrated here is that macavity's own fault
# configuration never crosses sessions: it is a backend-local variable, so
# session B cannot inherit, observe or be fired by session A's fault.
#
# That is a separate matter from what PostgreSQL does after a backend
# crashes.  When the 'crash' action kills a backend, the postmaster
# terminates the other backends as well and runs crash recovery, and those
# clients see "terminating connection because of crash of another server
# process".  Those sessions are disconnected by the server's crash
# containment; they did not inherit a macavity fault, and none of them ever
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

echo "1..3  macavity session isolation"

# --- 1: an armed fault does not exist for another session --------------
# Session A arms a fault and, in the same connection, proves it fired.
a_out=$(psql_script <<'SQL'
SELECT macavity_arm('executor_start', 'error');
SELECT 'session-a-statement' AS marker;
SQL
)
echo "$a_out" | grep -q 'injected error at fault point "executor_start"' ||
	fail "session A did not see its own fault fire (got: $a_out)"
echo "ok 1  - session A's fault fires in session A"

# --- 2: a fresh session sees no fault ---------------------------------
b_out=$(psql_script <<'SQL'
SELECT armed FROM macavity_status();
SELECT 'session-b-statement' AS marker;
SQL
)
echo "$b_out" | grep -q '^f$' || fail "session B reports a fault armed: $b_out"
echo "$b_out" | grep -q 'session-b-statement' ||
	fail "session B's statement did not run: $b_out"
echo "ok 2  - session B is unaffected and reports nothing armed"

# --- 3: state does not survive the session ----------------------------
# Session A armed a fault at a high occurrence and disconnects without
# disarming; a later session must still start clean.
psql_q "SELECT macavity_arm('executor_start', 'error', 9999)" >/dev/null
c_out=$(psql_q "SELECT armed FROM macavity_status()")
[ "$c_out" = "f" ] ||
	fail "a new session inherited fault state from a previous one: $c_out"
echo "ok 3  - fault state does not outlive the session that armed it"

echo
echo "# All 3 session-isolation tests passed."
