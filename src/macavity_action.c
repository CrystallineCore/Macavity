/*-------------------------------------------------------------------------
 *
 * macavity_action.c
 *		Fault action execution for macavity.
 *
 * Layer 4 of the design: the dispatcher that actually does the damage.
 * Adding a new action means adding a case here plus an entry in
 * macavity_action_info[]; no other layer needs to change.
 *
 * WARNING: the "crash" action deliberately terminates the current backend
 * with SIGKILL.  This is destructive by design.  Read README.md before
 * loading this extension anywhere you care about.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <signal.h>
#include <unistd.h>

#include "miscadmin.h"
#include "pgstat.h"
#include "storage/latch.h"
#include "utils/timestamp.h"

#include "macavity.h"

/*
 * macavity_do_delay
 *
 * Sleep for MACAVITY_DELAY_MS.
 *
 * When interrupts are safe to service we sleep on the process latch, so the
 * delay still honours statement_timeout and query cancellation.  During
 * transaction abort processing neither is true -- throwing an error out of
 * an abort callback would escalate to FATAL -- so there we use a plain
 * uninterruptible sleep.
 */
static void
macavity_do_delay(bool interrupts_safe)
{
	TimestampTz endtime;

	if (!interrupts_safe)
	{
		pg_usleep(MACAVITY_DELAY_MS * 1000L);
		return;
	}

	endtime = TimestampTzPlusMilliseconds(GetCurrentTimestamp(),
										  MACAVITY_DELAY_MS);

	for (;;)
	{
		TimestampTz now = GetCurrentTimestamp();
		long		remaining_ms;

		if (now >= endtime)
			break;

		/* microseconds -> milliseconds, rounded up so we never busy-loop */
		remaining_ms = (long) ((endtime - now + 999) / 1000);

		ResetLatch(MyLatch);
		(void) WaitLatch(MyLatch,
						 WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
						 remaining_ms,
						 PG_WAIT_EXTENSION);
		CHECK_FOR_INTERRUPTS();
	}
}

/*
 * macavity_do_crash
 *
 * Terminate *this* backend immediately and uncleanly.
 *
 * SIGKILL is sent to MyProcPid and to nothing else: macavity never signals
 * the postmaster and never signals another backend.  Note, however, that
 * PostgreSQL's own architecture means an unclean backend exit causes the
 * postmaster to reset the whole cluster and run crash recovery, which
 * disconnects other sessions.  That is inherent to simulating a crash and
 * is exactly why this extension is for test clusters only.
 */
static void
macavity_do_crash(MacavityPoint point)
{
	/*
	 * Log before dying.  ereport(LOG) writes through to the server log
	 * synchronously, so this line survives the SIGKILL that follows.
	 */
	ereport(LOG,
			(errmsg("macavity: crashing backend (PID %d) at fault point \"%s\"",
					MyProcPid, macavity_point_name(point)),
			 errdetail("The backend is being terminated with SIGKILL by an armed macavity fault."),
			 errhint("The postmaster will treat this as a backend crash and reinitialize the cluster.")));

	kill(MyProcPid, SIGKILL);

	/*
	 * Not reached.  If SIGKILL were somehow blocked or ignored we must not
	 * silently continue as if the fault had not happened.
	 */
	elog(PANIC, "macavity: SIGKILL to own backend did not terminate it");
}

/*
 * macavity_execute_action
 *
 * Run one fault action.  The fault has already been disarmed by
 * macavity_event(), so nothing here needs to worry about re-entry.
 */
void
macavity_execute_action(MacavityPoint point, MacavityAction action)
{
	bool		interrupts_safe = (point != MACAVITY_POINT_BEFORE_ABORT);

	switch (action)
	{
		case MACAVITY_ACTION_ERROR:

			/*
			 * macavity_arm() refuses error+before_abort, because raising an
			 * error while the transaction is already aborting escalates to
			 * FATAL.  Defend the invariant here as well rather than trusting
			 * a future caller.
			 */
			if (!interrupts_safe)
			{
				ereport(WARNING,
						(errmsg("macavity: suppressing injected error at fault point \"%s\"",
								macavity_point_name(point)),
						 errdetail("Raising an error during transaction abort processing would escalate to FATAL.")));
				return;
			}

			ereport(ERROR,
					(errcode(ERRCODE_RAISE_EXCEPTION),
					 errmsg("macavity: injected error at fault point \"%s\"",
							macavity_point_name(point))));
			break;

		case MACAVITY_ACTION_CRASH:
			macavity_do_crash(point);
			break;

		case MACAVITY_ACTION_DELAY:
			ereport(DEBUG1,
					(errmsg("macavity: injecting %d ms delay at fault point \"%s\"",
							MACAVITY_DELAY_MS, macavity_point_name(point))));
			macavity_do_delay(interrupts_safe);
			break;

		case MACAVITY_ACTION_INVALID:
		case MACAVITY_NUM_ACTIONS:
			elog(ERROR, "macavity: unexpected action %d", (int) action);
			break;
	}
}
