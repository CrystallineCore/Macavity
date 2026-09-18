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
int		macavity_exec_nesting = 0;

/*
 * macavity_fire
 *
 * Count one event at 'point' and run the action if this is the configured
 * occurrence.  Note that macavity_event() disarms the fault before we get
 * here, so an action that throws (or kills the backend) cannot re-enter.
 */
static void
macavity_fire(MacavityPoint point)
{
	MacavityAction action;

	if (macavity_event(point, &action))
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
 * Nesting bookkeeping only.  PG_FINALLY keeps the counter correct when the
 * executed query throws -- including when the error is one macavity itself
 * injected.
 */
#if PG_VERSION_NUM >= 180000
/* execute_once was removed from the executor API in PostgreSQL 18. */
static void
mac_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count)
#else
static void
mac_ExecutorRun(QueryDesc *queryDesc, ScanDirection direction, uint64 count,
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
	PG_FINALLY();
	{
		macavity_exec_nesting--;
	}
	PG_END_TRY();
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
	PG_FINALLY();
	{
		macavity_exec_nesting--;
	}
	PG_END_TRY();
}

/*
 * ExecutorEnd_hook
 *
 * The fault is injected after the executor has been shut down, so the point
 * really is "after execution completed".
 *
 * The statement that called macavity_arm() reaches its own ExecutorEnd
 * after the arming function has returned; counting that would fire the
 * fault before the caller could run anything else, so exactly one event is
 * skipped for it.
 */
static void
mac_ExecutorEnd(QueryDesc *queryDesc)
{
	if (prev_ExecutorEnd)
		prev_ExecutorEnd(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);

	if (!macavity_consume_exec_end_skip())
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
 * to parallel workers and to two-phase commit, neither of which v0.1
 * claims to cover.
 */
static void
mac_xact_callback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_PRE_COMMIT:
			if (!macavity_consume_xact_skip())
				macavity_fire(MACAVITY_POINT_BEFORE_COMMIT);
			break;

		case XACT_EVENT_ABORT:
			if (!macavity_consume_xact_skip())
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
