/*-------------------------------------------------------------------------
 *
 * macavity.h
 *		Shared declarations for the macavity fault-injection extension.
 *
 * macavity is DESTRUCTIVE testing infrastructure.  It is intended for
 * development and test clusters only.  See README.md.
 *
 *-------------------------------------------------------------------------
 */
#ifndef MACAVITY_H
#define MACAVITY_H

#include "postgres.h"

#include "fmgr.h"

/*
 * Duration of the "delay" action.  v0.1 deliberately does not expose this
 * through the SQL API; a later version can add an optional argument without
 * breaking the existing signature.
 */
#define MACAVITY_DELAY_MS		1000

/*
 * Supported fault points.  Keep in sync with macavity_point_info[].
 */
typedef enum MacavityPoint
{
	MACAVITY_POINT_INVALID = -1,
	MACAVITY_POINT_EXECUTOR_START = 0,
	MACAVITY_POINT_EXECUTOR_END,
	MACAVITY_POINT_BEFORE_COMMIT,
	MACAVITY_POINT_BEFORE_ABORT,
	MACAVITY_NUM_POINTS
} MacavityPoint;

/*
 * Supported actions.  Keep in sync with macavity_action_info[].
 */
typedef enum MacavityAction
{
	MACAVITY_ACTION_INVALID = -1,
	MACAVITY_ACTION_ERROR = 0,
	MACAVITY_ACTION_CRASH,
	MACAVITY_ACTION_DELAY,
	MACAVITY_NUM_ACTIONS
} MacavityAction;

typedef struct MacavityNameInfo
{
	const char *name;
	const char *description;
} MacavityNameInfo;

/*
 * The fault armed in *this* backend.
 *
 * Fault configuration is intentionally a plain backend-local static.  No
 * shared memory, locks or IPC are involved, so one session can neither
 * observe nor disturb another session's configuration.
 */
typedef struct MacavityFaultState
{
	bool		armed;
	MacavityPoint point;
	MacavityAction action;
	int32		occurrence;		/* which matching event fires the fault */
	int32		hits;			/* matching events counted so far */

	/*
	 * Bookkeeping that keeps the statement/transaction which armed the fault
	 * from being counted as a matching event.  See macavity_state.c.
	 */
	int		skip_exec_end_depth;	/* -1 when unused */
	bool		skip_xact_event;
} MacavityFaultState;

/* Executor nesting depth, maintained by the hook layer (macavity.c). */
extern int	macavity_exec_nesting;

/* --- fault state management (macavity_state.c) --------------------------- */

extern const MacavityNameInfo macavity_point_info[MACAVITY_NUM_POINTS];
extern const MacavityNameInfo macavity_action_info[MACAVITY_NUM_ACTIONS];

extern const MacavityFaultState *macavity_state(void);
extern MacavityPoint macavity_point_lookup(const char *name);
extern MacavityAction macavity_action_lookup(const char *name);
extern const char *macavity_point_name(MacavityPoint point);
extern const char *macavity_action_name(MacavityAction action);

extern void macavity_fault_arm(MacavityPoint point, MacavityAction action,
							   int32 occurrence);
extern void macavity_fault_disarm(void);
extern void macavity_set_xact_skip(void);

/*
 * Count one event at 'point'.  Returns true (and stores the configured
 * action in *action) when this event is the configured occurrence.  The
 * fault is disarmed before returning: v0.1 faults are strictly one-shot.
 */
extern bool macavity_event(MacavityPoint point, MacavityAction *action);

/* Helpers used by the hook layer to ignore the arming statement/transaction. */
extern bool macavity_consume_exec_end_skip(void);
extern bool macavity_consume_xact_skip(void);
extern void macavity_xact_cleanup(void);

/* --- fault action execution (macavity_action.c) -------------------------- */

extern void macavity_execute_action(MacavityPoint point, MacavityAction action);

#endif							/* MACAVITY_H */
