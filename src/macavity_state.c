/*-------------------------------------------------------------------------
 *
 * macavity_state.c
 *		Session-local fault state for macavity.
 *
 * Layer 2 of the design: everything that knows what a fault *is* lives
 * here.  This file performs no ereport(ERROR) of its own for invalid input;
 * validation belongs to the SQL layer (macavity_api.c) so error messages and
 * SQLSTATEs stay in one place.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "macavity.h"

/*
 * Only points that are genuinely implemented on top of a supported
 * PostgreSQL extension hook appear here.  macavity_points() reads straight
 * out of this array, so an unimplemented point cannot be advertised by
 * accident.
 */
const MacavityNameInfo macavity_point_info[MACAVITY_NUM_POINTS] = {
	{"executor_start", "before executor execution begins (ExecutorStart_hook)"},
	{"executor_end", "after executor execution completes (ExecutorEnd_hook)"},
	{"before_commit", "before transaction commit processing (XACT_EVENT_PRE_COMMIT)"},
	{"before_abort", "during transaction abort processing (XACT_EVENT_ABORT)"}
};

const MacavityNameInfo macavity_action_info[MACAVITY_NUM_ACTIONS] = {
	{"error", "raise an ERROR"},
	{"crash", "terminate this backend immediately (SIGKILL to own PID)"},
	{"delay", "sleep for a fixed duration"}
};

/*
 * The armed fault of this backend.  Backend-local by construction: see the
 * comment on MacavityFaultState.
 */
static MacavityFaultState fault_state = {
	.armed = false,
	.fired = false,
	.point = MACAVITY_POINT_INVALID,
	.action = MACAVITY_ACTION_INVALID,
	.occurrence = 0,
	.hits = 0,
	.skip_exec_end_depth = -1,
	.skip_xact_event = false
};

const MacavityFaultState *
macavity_state(void)
{
	return &fault_state;
}

MacavityPoint
macavity_point_lookup(const char *name)
{
	for (int i = 0; i < MACAVITY_NUM_POINTS; i++)
	{
		if (strcmp(name, macavity_point_info[i].name) == 0)
			return (MacavityPoint) i;
	}
	return MACAVITY_POINT_INVALID;
}

MacavityAction
macavity_action_lookup(const char *name)
{
	for (int i = 0; i < MACAVITY_NUM_ACTIONS; i++)
	{
		if (strcmp(name, macavity_action_info[i].name) == 0)
			return (MacavityAction) i;
	}
	return MACAVITY_ACTION_INVALID;
}

const char *
macavity_point_name(MacavityPoint point)
{
	if (point < 0 || point >= MACAVITY_NUM_POINTS)
		return "invalid";
	return macavity_point_info[point].name;
}

const char *
macavity_action_name(MacavityAction action)
{
	if (action < 0 || action >= MACAVITY_NUM_ACTIONS)
		return "invalid";
	return macavity_action_info[action].name;
}

/*
 * macavity_fault_arm
 *
 * Install a fault.  Callers must have validated point, action and
 * occurrence already.
 *
 * Arming happens *while* a statement (and a transaction) is running: the
 * SELECT that called macavity_arm().  Counting that statement's own
 * ExecutorEnd, or the implicit commit of that same statement, as a matching
 * event would make the fault fire before the caller could do anything, so
 * two one-shot skips are set up here:
 *
 * - executor_end: the ExecutorEnd of the statement that armed the fault runs
 *	 at one nesting level below the level we are currently executing at
 *	 (ExecutorEnd is called after ExecutorRun has returned and the hook layer
 *	 has decremented the counter).  Remember that depth and skip exactly one
 *	 event there.
 *
 * - before_commit / before_abort: only skip when we are NOT inside an
 *	 explicit transaction block.  In autocommit mode the imminent commit
 *	 belongs to the arming statement itself and must be ignored; inside
 *	 BEGIN ... COMMIT the user's own COMMIT is a legitimate target and is
 *	 counted normally.
 */
void
macavity_fault_arm(MacavityPoint point, MacavityAction action, int32 occurrence)
{
	Assert(point >= 0 && point < MACAVITY_NUM_POINTS);
	Assert(action >= 0 && action < MACAVITY_NUM_ACTIONS);
	Assert(occurrence > 0);

	fault_state.armed = true;
	fault_state.fired = false;		/* forget any previously spent fault */
	fault_state.point = point;
	fault_state.action = action;
	fault_state.occurrence = occurrence;
	fault_state.hits = 0;
	fault_state.skip_exec_end_depth = -1;
	fault_state.skip_xact_event = false;

	if (point == MACAVITY_POINT_EXECUTOR_END)
		fault_state.skip_exec_end_depth = macavity_exec_nesting - 1;
}

/*
 * macavity_fault_disarm
 *
 * Clear the fault state completely, including the record of a fault that
 * has already fired.  After this the session is indistinguishable from one
 * that has never armed anything.
 */
void
macavity_fault_disarm(void)
{
	fault_state.armed = false;
	fault_state.fired = false;
	fault_state.point = MACAVITY_POINT_INVALID;
	fault_state.action = MACAVITY_ACTION_INVALID;
	fault_state.occurrence = 0;
	fault_state.hits = 0;
	fault_state.skip_exec_end_depth = -1;
	fault_state.skip_xact_event = false;
}

/*
 * macavity_set_xact_skip
 *
 * Called from the SQL layer, which knows (via IsTransactionBlock()) whether
 * the imminent transaction end belongs to the arming statement.
 */
void
macavity_set_xact_skip(void)
{
	fault_state.skip_xact_event = true;
}

/*
 * macavity_consume_exec_end_skip
 *
 * Returns true when this executor_end event is the arming statement's own
 * and must not be counted.  The skip is one-shot.
 */
bool
macavity_consume_exec_end_skip(void)
{
	if (!fault_state.armed)
		return false;
	if (fault_state.skip_exec_end_depth < 0)
		return false;
	if (macavity_exec_nesting != fault_state.skip_exec_end_depth)
		return false;

	fault_state.skip_exec_end_depth = -1;
	return true;
}

bool
macavity_consume_xact_skip(void)
{
	if (!fault_state.skip_xact_event)
		return false;

	fault_state.skip_xact_event = false;
	return true;
}

/*
 * macavity_xact_cleanup
 *
 * Called at the end of every transaction.  The pending-skip flags are
 * transient state about a specific transaction and must never leak into the
 * next one; the armed fault itself deliberately survives, so a fault can be
 * armed in one transaction and fire in a later one.
 */
void
macavity_xact_cleanup(void)
{
	fault_state.skip_xact_event = false;
}

/*
 * macavity_event
 *
 * Record one matching event and decide whether it fires the fault.
 *
 * Order matters here, and it is the whole point of this function:
 *
 *		1. the hit is counted	 (hits++, so remaining falls by one)
 *		2. the threshold is tested
 *		3. the fault is marked spent
 *		4. ... and only then does the caller run the action
 *
 * Counting first means the hit is recorded even when the action never
 * returns -- an injected ERROR unwinds past the caller, and 'crash' kills
 * the backend outright.  If the counter were bumped afterwards, the very
 * hit that fired the fault would be the one missing from
 * macavity_status().
 *
 * Marking the fault spent before the action also makes the behaviour
 * reliably one-shot: there is no window in which the error being unwound
 * could re-enter the hook and fire the fault a second time.
 *
 * Spent is not the same as disarmed.  'armed' goes false so nothing fires
 * again, but the point, action, occurrence and counters are kept so the
 * caller can confirm afterwards what happened; macavity_fault_disarm() is
 * what actually clears them.
 */
bool
macavity_event(MacavityPoint point, MacavityAction *action)
{
	if (!fault_state.armed)
		return false;
	if (fault_state.point != point)
		return false;

	/* 1. record the hit, before anything can stop us doing so */
	fault_state.hits++;

	/* 2. not this one? leave the fault armed and keep counting */
	if (fault_state.hits < fault_state.occurrence)
		return false;

	/* 3. this is the configured occurrence: spend the fault */
	fault_state.armed = false;
	fault_state.fired = true;
	fault_state.skip_exec_end_depth = -1;
	fault_state.skip_xact_event = false;

	/* 4. the caller runs this once we return */
	*action = fault_state.action;
	return true;
}
