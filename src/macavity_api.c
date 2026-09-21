/*-------------------------------------------------------------------------
 *
 * macavity_api.c
 *		SQL-callable interface for macavity.
 *
 * Layer 1 of the design: argument validation and result formatting.  All
 * user-facing error messages and SQLSTATEs live here; the state layer below
 * assumes its inputs are already valid.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/xact.h"
#include "funcapi.h"
#include "utils/builtins.h"

#include "macavity.h"

PG_FUNCTION_INFO_V1(macavity_arm);
PG_FUNCTION_INFO_V1(macavity_arm_event);
PG_FUNCTION_INFO_V1(macavity_arm_error);
PG_FUNCTION_INFO_V1(macavity_arm_delay);
PG_FUNCTION_INFO_V1(macavity_arm_crash);
PG_FUNCTION_INFO_V1(macavity_disarm);
PG_FUNCTION_INFO_V1(macavity_status);
PG_FUNCTION_INFO_V1(macavity_points);
PG_FUNCTION_INFO_V1(macavity_reset);

#define MACAVITY_STATUS_COLS	7

/*
 * Build the "point1, point2, ..." style hints used by the validation
 * errors, so a typo is answered with the actual list of what works.
 */
static char *
macavity_name_list(const MacavityNameInfo *info, int count)
{
	StringInfoData buf;

	initStringInfo(&buf);
	for (int i = 0; i < count; i++)
	{
		if (i > 0)
			appendStringInfoString(&buf, ", ");
		appendStringInfoString(&buf, info[i].name);
	}
	return buf.data;
}

/*
 * macavity_after_arm
 *
 * Common tail of every path that puts an event into the armed state, new or
 * reinstated.
 *
 * In autocommit mode the transaction that is about to end belongs to the
 * arming statement itself, so its commit must not count as a matching hit.
 * Inside an explicit BEGIN ... COMMIT block the user's own COMMIT is a
 * legitimate target and is counted normally.
 */
static void
macavity_after_arm(int32 event_id)
{
	const MacavityEvent *ev = macavity_event_get(event_id);

	if ((ev->point == MACAVITY_POINT_BEFORE_COMMIT ||
		 ev->point == MACAVITY_POINT_BEFORE_ABORT) &&
		!IsTransactionBlock())
		macavity_event_set_xact_skip(event_id);
}

/*
 * macavity_checked_point
 *
 * Look up a fault point by name, or report the list of supported ones.
 */
static MacavityPoint
macavity_checked_point(text *point_text)
{
	char    *point_name = text_to_cstring(point_text);
	MacavityPoint point = macavity_point_lookup(point_name);

	if (point == MACAVITY_POINT_INVALID)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("macavity: unrecognized fault point \"%s\"", point_name),
				 errhint("Supported fault points are: %s. See macavity_points().",
						 macavity_name_list(macavity_point_info, MACAVITY_NUM_POINTS))));
	return point;
}

/*
 * macavity_create_event
 *
 * The one place a new event is validated and created.  macavity_arm() and
 * the action-specific macavity_arm_<action>() functions all come through
 * here; they differ only in where the action comes from.
 */
static int32
macavity_create_event(MacavityPoint point, MacavityAction action,
					  int32 occurrence)
{
	int32		event_id;

	if (occurrence <= 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("macavity: occurrence must be greater than zero, got %d",
						occurrence)));

	/*
	 * XACT_EVENT_ABORT fires when the transaction is already aborting.
	 * Raising an error from there escalates to FATAL and disconnects the
	 * session, which is not what "error" is supposed to mean, so refuse the
	 * combination up front instead of surprising the caller later.
	 */
	if (point == MACAVITY_POINT_BEFORE_ABORT && action == MACAVITY_ACTION_ERROR)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("macavity: action \"error\" is not supported at fault point \"before_abort\""),
				 errdetail("PostgreSQL has no pre-abort hook; the abort is already in progress when this point is reached, so raising an error there would escalate to FATAL."),
				 errhint("Use action \"crash\" or \"delay\" at \"before_abort\", or arm \"error\" at \"before_commit\".")));

	event_id = macavity_event_create(point, action, occurrence);
	macavity_after_arm(event_id);

	return event_id;
}

/*
 * macavity_arm(point text, action text, occurrence integer DEFAULT 1)
 *
 * Creates a new armed event in the current session and returns its ID.
 * Declared non-strict so a NULL argument is reported rather than silently
 * ignored.
 */
Datum
macavity_arm(PG_FUNCTION_ARGS)
{
	char	   *action_name;
	MacavityPoint point;
	MacavityAction action;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1) || PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("macavity: point, action and occurrence must not be null")));

	point = macavity_checked_point(PG_GETARG_TEXT_PP(0));

	action_name = text_to_cstring(PG_GETARG_TEXT_PP(1));
	action = macavity_action_lookup(action_name);
	if (action == MACAVITY_ACTION_INVALID)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("macavity: unrecognized action \"%s\"", action_name),
				 errhint("Supported actions are: %s.",
						 macavity_name_list(macavity_action_info, MACAVITY_NUM_ACTIONS))));

	PG_RETURN_INT32(macavity_create_event(point, action, PG_GETARG_INT32(2)));
}

/*
 * macavity_arm_<action>(point text, occurrence integer DEFAULT 1)
 *
 * Shorthand for macavity_arm(point, '<action>', occurrence): same
 * validation, same event, same returned ID.
 */
static Datum
macavity_arm_action(FunctionCallInfo fcinfo, MacavityAction action)
{
	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("macavity: point and occurrence must not be null")));

	PG_RETURN_INT32(macavity_create_event(macavity_checked_point(PG_GETARG_TEXT_PP(0)),
										  action,
										  PG_GETARG_INT32(1)));
}

Datum
macavity_arm_error(PG_FUNCTION_ARGS)
{
	return macavity_arm_action(fcinfo, MACAVITY_ACTION_ERROR);
}

Datum
macavity_arm_delay(PG_FUNCTION_ARGS)
{
	return macavity_arm_action(fcinfo, MACAVITY_ACTION_DELAY);
}

Datum
macavity_arm_crash(PG_FUNCTION_ARGS)
{
	return macavity_arm_action(fcinfo, MACAVITY_ACTION_CRASH);
}

/*
 * macavity_arm(event_id integer)
 *
 * Reinstates an existing event: a completed or disarmed event goes back to
 * armed with its original ID and configuration, and hits reset to 0.
 * Returns true if the event changed state; false if it was already armed,
 * in which case it is left completely untouched, counters included.
 * An ID that is not in the registry is an error: there is nothing to
 * reinstate.
 */
Datum
macavity_arm_event(PG_FUNCTION_ARGS)
{
	int32		event_id;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("macavity: event_id must not be null")));

	event_id = PG_GETARG_INT32(0);
	if (macavity_event_get(event_id) == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("macavity: event %d does not exist in this session", event_id),
				 errhint("See macavity_status() for this session's events.")));

	if (!macavity_event_rearm(event_id))
		PG_RETURN_BOOL(false);

	macavity_after_arm(event_id);
	PG_RETURN_BOOL(true);
}

/*
 * macavity_disarm(event_id integer DEFAULT NULL)
 *
 * With an ID, disarms that one event; with NULL (the default), disarms
 * every armed event.  Returns true if at least one event went from armed to
 * disarmed.  Completed and already-disarmed events are left alone, and an
 * unknown ID simply returns false.
 */
Datum
macavity_disarm(PG_FUNCTION_ARGS)
{
	if (PG_NARGS() == 0 || PG_ARGISNULL(0))
		PG_RETURN_BOOL(macavity_event_disarm_all());

	PG_RETURN_BOOL(macavity_event_disarm(PG_GETARG_INT32(0)));
}

/*
 * macavity_status()
 *
 * One row per event in this session's registry, in event_id order,
 * whatever its state:
 *
 *	armed		hits counts the matching hits seen so far and remaining is
 *		        occurrence - hits.
 *	completed	the event fired; its final counters are kept, so a caller can
 *			confirm after the fact that the hit was recorded before the
 *			action ran (remaining is 0).
 *	disarmed	        cancelled before it fired; the counters show how far it got.
 *
 * An empty registry (a brand-new session, or one just reset) returns no
 * rows.
 */
Datum
macavity_status(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int32		count;

	InitMaterializedSRF(fcinfo, 0);

	/*
	 * Snapshot the count first: this query is itself a fault-point hit, but
	 * nothing it does can add events while we are reading.
	 */
	count = macavity_event_count();

	for (int32 id = 1; id <= count; id++)
	{
		const MacavityEvent *ev = macavity_event_get(id);
		Datum		values[MACAVITY_STATUS_COLS];
		bool		nulls[MACAVITY_STATUS_COLS];

		memset(nulls, false, sizeof(nulls));

		values[0] = Int32GetDatum(ev->event_id);
		values[1] = CStringGetTextDatum(macavity_point_name(ev->point));
		values[2] = CStringGetTextDatum(macavity_action_name(ev->action));
		values[3] = Int32GetDatum(ev->occurrence);
		values[4] = Int32GetDatum(ev->hits);
		values[5] = Int32GetDatum(ev->occurrence - ev->hits);
		values[6] = CStringGetTextDatum(macavity_event_state_name(ev->state));

		tuplestore_puttuple(rsinfo->setResult,
							heap_form_tuple(rsinfo->setDesc, values, nulls));
	}

	return (Datum) 0;
}

/*
 * macavity_reset()
 *
 * Discards the whole registry -- armed, completed and disarmed events alike
 * -- and restarts event ID allocation at 1.  Returns the number of events
 * discarded.
 */
Datum
macavity_reset(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(macavity_registry_reset());
}

/*
 * macavity_points()
 *
 * The fault points this build actually implements, read straight out of
 * macavity_point_info[] so nothing unimplemented can be advertised.
 */
Datum
macavity_points(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);

	for (int i = 0; i < MACAVITY_NUM_POINTS; i++)
	{
		Datum		values[2];
		bool		nulls[2] = {false, false};

		values[0] = CStringGetTextDatum(macavity_point_info[i].name);
		values[1] = CStringGetTextDatum(macavity_point_info[i].description);

		tuplestore_puttuple(rsinfo->setResult, heap_form_tuple(rsinfo->setDesc, values, nulls));
	}

	return (Datum) 0;
}
