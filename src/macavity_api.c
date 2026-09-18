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
PG_FUNCTION_INFO_V1(macavity_disarm);
PG_FUNCTION_INFO_V1(macavity_status);
PG_FUNCTION_INFO_V1(macavity_points);

#define MACAVITY_STATUS_COLS	6

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
 * macavity_arm(point text, action text, occurrence integer DEFAULT 1)
 *
 * Arms a one-shot fault in the current session.  Declared non-strict so a
 * NULL argument is reported rather than silently ignored.
 */
Datum
macavity_arm(PG_FUNCTION_ARGS)
{
	char	   *point_name;
	char	   *action_name;
	int32		occurrence;
	MacavityPoint point;
	MacavityAction action;
	const MacavityFaultState *state;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1) || PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("macavity: point, action and occurrence must not be null")));

	point_name = text_to_cstring(PG_GETARG_TEXT_PP(0));
	action_name = text_to_cstring(PG_GETARG_TEXT_PP(1));
	occurrence = PG_GETARG_INT32(2);

	point = macavity_point_lookup(point_name);
	if (point == MACAVITY_POINT_INVALID)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("macavity: unrecognized fault point \"%s\"", point_name),
				 errhint("Supported fault points are: %s. See macavity_points().",
						 macavity_name_list(macavity_point_info, MACAVITY_NUM_POINTS))));

	action = macavity_action_lookup(action_name);
	if (action == MACAVITY_ACTION_INVALID)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("macavity: unrecognized action \"%s\"", action_name),
				 errhint("Supported actions are: %s.",
						 macavity_name_list(macavity_action_info, MACAVITY_NUM_ACTIONS))));

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

	state = macavity_state();
	if (state->armed)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("macavity: a fault is already armed in this session"),
				 errdetail("Fault point \"%s\" with action \"%s\" is armed at occurrence %d (%d matching events so far).",
						   macavity_point_name(state->point),
						   macavity_action_name(state->action),
						   state->occurrence, state->hits),
				 errhint("Call macavity_disarm() first.")));

	macavity_fault_arm(point, action, occurrence);

	/*
	 * In autocommit mode the transaction that is about to end belongs to
	 * this very statement, so its commit must not count as a matching
	 * event.  Inside an explicit BEGIN ... COMMIT block the user's own
	 * COMMIT is a legitimate target and is counted normally.
	 */
	if ((point == MACAVITY_POINT_BEFORE_COMMIT ||
		 point == MACAVITY_POINT_BEFORE_ABORT) &&
		!IsTransactionBlock())
		macavity_set_xact_skip();

	PG_RETURN_VOID();
}

/*
 * macavity_disarm()
 *
 * Removes this session's armed fault.  Safe to call when nothing is armed.
 */
Datum
macavity_disarm(PG_FUNCTION_ARGS)
{
	macavity_fault_disarm();
	PG_RETURN_VOID();
}

/*
 * macavity_status()
 *
 * One row describing this session's fault, in one of three states:
 *
 *	armed		armed is true; hits counts the matching events seen so far
 *				and remaining is occurrence - hits.
 *	fired		armed is false, but the point, action and final counters are
 *				still reported, so a caller can confirm after the fact that
 *				the hit was recorded before the action ran (remaining is 0).
 *	clear		nothing armed and nothing fired since the last disarm (or a
 *				brand-new session): armed is false and every other column is
 *				NULL.
 *
 * "fired" and "clear" are told apart by point being non-NULL in the first
 * and NULL in the second.
 */
Datum
macavity_status(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[MACAVITY_STATUS_COLS];
	bool		nulls[MACAVITY_STATUS_COLS];
	const MacavityFaultState *state = macavity_state();

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "macavity: return type must be a row type");

	memset(values, 0, sizeof(values));
	memset(nulls, false, sizeof(nulls));

	values[0] = BoolGetDatum(state->armed);

	if (!state->armed && !state->fired)
	{
		for (int i = 1; i < MACAVITY_STATUS_COLS; i++)
			nulls[i] = true;
	}
	else
	{
		values[1] = CStringGetTextDatum(macavity_point_name(state->point));
		values[2] = CStringGetTextDatum(macavity_action_name(state->action));
		values[3] = Int32GetDatum(state->occurrence);
		values[4] = Int32GetDatum(state->hits);
		values[5] = Int32GetDatum(state->occurrence - state->hits);
	}

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
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

		tuplestore_puttuple(rsinfo->setResult,
							heap_form_tuple(rsinfo->setDesc, values, nulls));
	}

	return (Datum) 0;
}
