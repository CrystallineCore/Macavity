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
 * macavity targets PostgreSQL 16 and later.
 */
#if PG_VERSION_NUM < 160000
#error "macavity requires PostgreSQL 16 or later"
#endif

/*
 * Duration of the "delay" action.  macavity does not yet expose this
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
 * Lifecycle state of one event.  Keep in sync with macavity_event_state_name().
 *
 *		armed		-- waiting for its occurrence; the only state that fires
 *		completed	-- reached its occurrence and fired (armed -> completed)
 *		disarmed	        -- cancelled by macavity_disarm() (armed -> disarmed)
 *
 * macavity_arm(event_id) takes a completed or disarmed event back to armed.
 */
typedef enum MacavityEventState
{
	MACAVITY_EVENT_ARMED = 0,
	MACAVITY_EVENT_COMPLETED,
	MACAVITY_EVENT_DISARMED
} MacavityEventState;

/*
 * The event registry is intentionally plain backend-local memory.  No
 * shared memory, locks or IPC are involved, so one session cannot observe
 * another session's Macavity events.
 *
 * This does not mean that an injected backend crash is isolated from other
 * PostgreSQL sessions at the process level. PostgreSQL may terminate other
 * server processes after detecting a backend crash as part of its crash
 * recovery and shared-memory safety mechanisms. Those sessions may therefore
 * lose their connections, even though their Macavity state is not shared
 * with the crashing session.
 *
 * It is also not transactional: an injected ERROR aborts the transaction
 * but does not roll the counters back, which lets a caller confirm
 * afterwards that the hit was recorded.
 *
 * Every event ever created stays in the registry, whatever its state, until
 * macavity_reset() or the end of the backend.  The registry is the history;
 * there is no separate log.
 */
typedef struct MacavityEvent
{
	int32		event_id;		/* backend-local, 1, 2, 3, ... */
	MacavityEventState state;
	MacavityPoint   point;
	MacavityAction  action;
	int32		occurrence;		/* which matching hit fires the event */
	int32		hits;			/* matching hits counted since last armed */

	/*
	 * Bookkeeping that keeps the statement/transaction which armed the event
	 * from being counted as a matching hit.  See macavity_state.c.
	 */
	int		skip_exec_end_depth;	/* -1 when unused */
	bool		skip_xact_event;
} MacavityEvent;

/*
 * Position of an in-progress scan over the armed events at one fault point,
 * in firing order.  See macavity_event_next().
 */
typedef struct MacavityEventScan
{
	MacavityPoint   point;
	int		rank;			/* index into the action precedence order */
	int		pos;			/* position within that action's bucket */
} MacavityEventScan;

/* Executor nesting depth, maintained by the hook layer (macavity.c). */
extern int	macavity_exec_nesting;

/* --- event registry (macavity_state.c) ----------------------------------- */

extern const MacavityNameInfo macavity_point_info[MACAVITY_NUM_POINTS];
extern const MacavityNameInfo macavity_action_info[MACAVITY_NUM_ACTIONS];

extern MacavityPoint macavity_point_lookup(const char *name);
extern MacavityAction macavity_action_lookup(const char *name);
extern const char *macavity_point_name(MacavityPoint point);
extern const char *macavity_action_name(MacavityAction action);
extern const char *macavity_event_state_name(MacavityEventState state);

/* Registry access: events are stored densely in event_id order. */
extern int32 macavity_event_count(void);
extern const MacavityEvent *macavity_event_get(int32 event_id);

/* Registry changes.  Callers must have validated their arguments. */
extern int32 macavity_event_create(MacavityPoint point, MacavityAction action, int32 occurrence);
extern bool macavity_event_rearm(int32 event_id);
extern bool macavity_event_disarm(int32 event_id);
extern bool macavity_event_disarm_all(void);
extern int32 macavity_registry_reset(void);
extern void macavity_event_set_xact_skip(int32 event_id);

/*
 * Walk the armed events at 'point' in firing order -- action precedence
 * delay > crash > error, then ascending event_id -- recording one hit on
 * each.
 *
 * For every armed event reached, the hit is counted first, unconditionally.
 * Only then is its occurrence threshold tested; if it is reached, the event
 * becomes completed (counters kept) and true is returned with its action
 * stored in *action.  The caller runs that action and calls again to
 * continue the walk, so the recorded hit survives an action that never
 * returns, and an action that never returns stops the walk there.
 */
extern void macavity_event_scan_begin(MacavityPoint point, MacavityEventScan *scan);
extern bool macavity_event_next(MacavityEventScan *scan, MacavityAction *action);

/*
 * Called by the hook layer when an error unwinds out of ExecutorRun or
 * ExecutorFinish, leaving the executor nesting depth at 'depth'.
 */
extern void macavity_exec_unwound(int depth);

/* Called at the end of every transaction, commit or abort. */
extern void macavity_xact_cleanup(void);

/* --- fault action execution (macavity_action.c) -------------------------- */

extern void macavity_execute_action(MacavityPoint point, MacavityAction action);

#endif							/* MACAVITY_H */
