/*-------------------------------------------------------------------------
 *
 * macavity.c
 *		Hook integration for macavity.
 *
 * Layer 3 of the design: this file is the only place that knows about
 * PostgreSQL's hook APIs.  It maps each supported fault point onto exactly
 * one documented extension hook:
 *
 *		executor_start	->	ExecutorStart_hook
 *		executor_end	->	ExecutorEnd_hook
 *		before_commit	->	RegisterXactCallback / XACT_EVENT_PRE_COMMIT
 *		before_abort	->	RegisterXactCallback / XACT_EVENT_ABORT
 *
 * ExecutorRun_hook and ExecutorFinish_hook are installed only to maintain
 * the executor nesting counter; they are never fault points themselves.
 *
 * All version-dependent signatures are isolated in this file.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "access/xact.h"
#include "executor/executor.h"
#include "miscadmin.h"
#include "utils/guc.h"
#include "macavity.h"

PG_MODULE_MAGIC;

void		_PG_init(void);

/* Saved previous hook values, so we chain instead of clobbering. */
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorRun_hook_type prev_ExecutorRun = NULL;
static ExecutorFinish_hook_type prev_ExecutorFinish = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;

/*
 * Executor nesting depth.  0 means "no ExecutorRun/ExecutorFinish is
 * currently on the stack in this backend".
 */
int  macavity_exec_nesting = 0;

/*
 * macavity_fire
 *
 * Record one hit at 'point' on every armed event there, running the action
 * of each event for which this is the configured occurrence.
 *
 * macavity_event_next() walks the events in firing order (delay > crash >
 * error, then ascending event_id).  It has already counted the hit and
 * marked the event completed by the time it returns true, so each action
 * below runs with that event's counters final: an error thrown here, or a
 * backend that never comes back from here, still leaves the hit recorded,
 * and the completed event cannot re-enter while the error is unwound.  An
 * action that does not return ends the walk; the remaining events are not
 * reached for this hit.
 */
static void
macavity_fire(MacavityPoint point)
{
	MacavityEventScan scan;
	MacavityAction action;

	macavity_event_scan_begin(point, &scan);
	while (macavity_event_next(&scan, &action))
		macavity_execute_action(point, action);
}

/*
 * ExecutorStart_hook
 *
 * The fault is injected after the executor has been initialized but before
 * any tuples are produced.  Injecting before initialization would leave the
 * QueryDesc half-built for no additional test value.
 */
static void
mac_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);

	macavity_fire(MACAVITY_POINT_EXECUTOR_START);
}

/*
 * ExecutorRun_hook / ExecutorFinish_hook
 *
 * Nesting bookkeeping only.  The PG_CATCH path keeps the counter correct
 * when the executed query throws -- including when the error is one
 * macavity itself injected.
 *
 * An error that propagates out of ExecutorRun/ExecutorFinish at a given
 * depth means the query running at that depth is dead: PostgreSQL does not
 * call ExecutorEnd for it.  If that query armed an executor_end event, the
 * one-shot skip reserved for its ExecutorEnd would otherwise stay pending
 * and swallow the next legitimate hit at that depth, so it is dropped here.
 * This also covers errors caught by a PL/pgSQL exception block, where no
 * transaction-level abort happens.
 */
#if PG_VERSION_NUM >= 180000
/* execute_once was removed from the executor API in PostgreSQL 18. */
static void mac_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
#else
static void mac_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count,
				bool execute_once)
#endif
{
	macavity_exec_nesting++;
	PG_TRY();
	{
#if PG_VERSION_NUM >= 180000
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count);
		else
			standard_ExecutorRun(queryDesc, direction, count);
#else
		if (prev_ExecutorRun)
			prev_ExecutorRun(queryDesc, direction, count, execute_once);
		else
			standard_ExecutorRun(queryDesc, direction, count, execute_once);
#endif
	}
	PG_CATCH();
	{
		macavity_exec_nesting--;
		macavity_exec_unwound(macavity_exec_nesting);
		PG_RE_THROW();
	}
	PG_END_TRY();
	macavity_exec_nesting--;
}

static void
mac_ExecutorFinish(QueryDesc *queryDesc)
{
	macavity_exec_nesting++;
	PG_TRY();
	{
		if (prev_ExecutorFinish)
			prev_ExecutorFinish(queryDesc);
		else
			standard_ExecutorFinish(queryDesc);
	}
	PG_CATCH();
	{
		macavity_exec_nesting--;
		macavity_exec_unwound(macavity_exec_nesting);
		PG_RE_THROW();
	}
	PG_END_TRY();
	macavity_exec_nesting--;
}

/*
 * ExecutorEnd_hook
 *
 * The fault is injected after the executor has been shut down, so the point
 * really is "after execution completed".
 *
 * The statement that called macavity_arm() reaches its own ExecutorEnd
 * after the arming function has returned; counting that would fire the
 * event before the caller could run anything else, so exactly one hit is
 * skipped for each event armed by it (see event_skip_hit()).
 */
static void
mac_ExecutorEnd(QueryDesc *queryDesc)
{
	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);

	macavity_fire(MACAVITY_POINT_EXECUTOR_END);
}

/*
 * Transaction callback.
 *
 * XACT_EVENT_PRE_COMMIT runs before the commit record is written and can
 * still safely raise an error, which is what makes before_commit a useful
 * point for the "error" action.
 *
 * XACT_EVENT_ABORT, by contrast, runs when the abort is already under way:
 * PostgreSQL has no pre-abort callback, so before_abort is necessarily
 * "during abort processing" and cannot raise an error.  macavity_arm()
 * rejects that combination; see README.md.
 *
 * The PARALLEL_* and *PREPARE* events are deliberately ignored: they belong
 * to parallel workers and to two-phase commit, neither of which macavity
 * claims to cover.
 */
static void
mac_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_PRE_COMMIT:
			macavity_fire(MACAVITY_POINT_BEFORE_COMMIT);
			break;

		case XACT_EVENT_ABORT:
			macavity_fire(MACAVITY_POINT_BEFORE_ABORT);
			macavity_xact_cleanup();
			break;

		case XACT_EVENT_COMMIT:
			macavity_xact_cleanup();
			break;

		case XACT_EVENT_PARALLEL_COMMIT:
		case XACT_EVENT_PARALLEL_ABORT:
		case XACT_EVENT_PARALLEL_PRE_COMMIT:
		case XACT_EVENT_PREPARE:
		case XACT_EVENT_PRE_PREPARE:
			break;
	}
}

/*
 * Module initialization.
 *
 * macavity can be loaded on demand (LOAD / CREATE EXTENSION triggers it
 * through the C function's library reference) or via
 * shared_preload_libraries / session_preload_libraries.  Nothing here
 * allocates shared memory, so on-demand loading is fully supported.
 */
void
_PG_init(void)
{
	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = mac_ExecutorStart;

	prev_ExecutorRun = ExecutorRun_hook;
	ExecutorRun_hook = mac_ExecutorRun;

	prev_ExecutorFinish = ExecutorFinish_hook;
	ExecutorFinish_hook = mac_ExecutorFinish;

	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = mac_ExecutorEnd;

	RegisterXactCallback(mac_xact_callback, NULL);
}
