/*-------------------------------------------------------------------------
 *
 * macavity_state.c
 *		Session-local event registry for macavity.
 *
 * Layer 2 of the design: everything that knows what an event *is* lives
 * here.  This file performs no ereport(ERROR) of its own for invalid input;
 * validation belongs to the SQL layer (macavity_api.c) so error messages and
 * SQLSTATEs stay in one place.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "utils/memutils.h"
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
 * Firing order at a fault point: delay > crash > error.  Within one action,
 * events fire in ascending event_id order.  Fixed, so that the outcome of
 * several events meeting at one hit is deterministic.
 */
static const MacavityAction action_precedence[MACAVITY_NUM_ACTIONS] = {
	MACAVITY_ACTION_DELAY,
	MACAVITY_ACTION_CRASH,
	MACAVITY_ACTION_ERROR
};

/*
 * The event registry of this backend.  Backend-local by construction: see
 * the comment on MacavityEvent.
 *
 * Events are stored densely in creation order, and IDs are handed out as
 * 1, 2, 3, ... and never reused until macavity_reset(), so event_id N always
 * lives at events[N - 1]: lookup by ID is O(1) and walking the array is
 * walking the registry in event_id order.
 *
 * Each (point, action) pair also has a bucket listing the IDs of its events.
 * Events are appended as they are created, so every bucket is already in
 * ascending event_id order, and firing order at a point is simply the
 * point's buckets taken in action precedence order.  Events never leave
 * their bucket -- state is checked when the bucket is walked -- so
 * disarming and re-arming never move anything.
 *
 * All of it lives in registry_cxt, so macavity_reset() is one
 * MemoryContextReset().
 */
typedef struct MacavityBucket
{
	int32	   *ids;
	int32	    count;
	int32	    capacity;
} MacavityBucket;

static MemoryContext registry_cxt = NULL;
static MacavityEvent *events = NULL;
static int32 num_events = 0;
static int32 max_events = 0;
static MacavityBucket buckets[MACAVITY_NUM_POINTS][MACAVITY_NUM_ACTIONS];

/* true while some event may have skip_xact_event set */
static bool xact_skip_pending = false;

/* Hard ceiling on the registry, well below int32 and MaxAllocSize. */
#define MACAVITY_MAX_EVENTS \
	((int32) Min((Size) PG_INT32_MAX, MaxAllocSize / sizeof(MacavityEvent)))

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

const char *
macavity_event_state_name(MacavityEventState state)
{
	switch (state)
	{
		case MACAVITY_EVENT_ARMED:
			return "armed";
		case MACAVITY_EVENT_COMPLETED:
			return "completed";
		case MACAVITY_EVENT_DISARMED:
			return "disarmed";
	}
	return "invalid";
}

int32
macavity_event_count(void)
{
	return num_events;
}

/*
 * macavity_event_get
 *
 * The event with this ID, or NULL if there is none.
 */
const MacavityEvent *
macavity_event_get(int32 event_id)
{
	if (event_id < 1 || event_id > num_events)
		return NULL;
	return &events[event_id - 1];
}

static MacavityEvent *
event_lookup(int32 event_id)
{
	return (MacavityEvent *) macavity_event_get(event_id);
}

/*
 * Grow an array held in registry_cxt so it has room for at least 'needed'
 * elements.  Doubling keeps creation amortized O(1).
 */
static void *
registry_grow(void *array, int32 *capacity, int32 needed, Size elemsize)
{
	int32		newcap;

	if (needed <= *capacity)
		return array;

	newcap = Max(*capacity, 8);
	while (newcap < needed)
		newcap = (newcap > MACAVITY_MAX_EVENTS / 2) ? MACAVITY_MAX_EVENTS : newcap * 2;

	if (array == NULL)
		array = MemoryContextAlloc(registry_cxt, (Size) newcap * elemsize);
	else
		array = repalloc(array, (Size) newcap * elemsize);
	*capacity = newcap;
	return array;
}

/*
 * event_start
 *
 * Put an event into the armed state with fresh counters.  Shared by
 * creation and re-arming, which is what makes a re-armed event a fresh
 * execution of the same configuration.
 *
 * Arming happens *while* a statement (and a transaction) is running: the
 * SELECT that called macavity_arm().  Counting that statement's own
 * ExecutorEnd, or the implicit commit of that same statement, as a matching
 * hit would make the event fire before the caller could do anything, so
 * two one-shot skips are set up:
 *
 * - executor_end: the ExecutorEnd of the statement that armed the event
 *	 runs at one nesting level below the level we are currently executing at
 *	 (ExecutorEnd is called after ExecutorRun has returned and the hook layer
 *	 has decremented the counter).  Remember that depth and skip exactly one
 *	 hit there.
 *
 * - before_commit / before_abort: only skip when we are NOT inside an
 *	 explicit transaction block.  In autocommit mode the imminent commit
 *	 belongs to the arming statement itself and must be ignored; inside
 *	 BEGIN ... COMMIT the user's own COMMIT is a legitimate target and is
 *	 counted normally.  The SQL layer knows which case applies and calls
 *	 macavity_event_set_xact_skip().
 */
static void
event_start(MacavityEvent *ev)
{
	ev->state = MACAVITY_EVENT_ARMED;
	ev->hits = 0;
	ev->skip_exec_end_depth = -1;
	ev->skip_xact_event = false;

	if (ev->point == MACAVITY_POINT_EXECUTOR_END)
		ev->skip_exec_end_depth = macavity_exec_nesting - 1;
}

/* Leave the armed state: nothing about the arming statement matters now. */
static void
event_stop(MacavityEvent *ev, MacavityEventState state)
{
	ev->state = state;
	ev->skip_exec_end_depth = -1;
	ev->skip_xact_event = false;
}

/*
 * macavity_event_create
 *
 * Add a new armed event to the registry and return its ID.  Callers must
 * have validated point, action and occurrence already.
 *
 * All allocation happens before anything is modified, so an out-of-memory
 * error leaves the registry exactly as it was.
 */
int32
macavity_event_create(MacavityPoint point, MacavityAction action,
					  int32 occurrence)
{
	MacavityBucket *bucket;
	MacavityEvent *ev;

	Assert(point >= 0 && point < MACAVITY_NUM_POINTS);
	Assert(action >= 0 && action < MACAVITY_NUM_ACTIONS);
	Assert(occurrence > 0);

	if (num_events >= MACAVITY_MAX_EVENTS)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("macavity: event registry is full (%d events)",
						num_events),
				 errhint("Call macavity_reset() to clear the registry.")));

	if (registry_cxt == NULL)
		registry_cxt = AllocSetContextCreate(TopMemoryContext,
											 "macavity event registry",
											 ALLOCSET_SMALL_SIZES);

	bucket = &buckets[point][action];
	events = registry_grow(events, &max_events, num_events + 1,
						   sizeof(MacavityEvent));
	bucket->ids = registry_grow(bucket->ids, &bucket->capacity,
								bucket->count + 1, sizeof(int32));

	ev = &events[num_events];
	ev->event_id = num_events + 1;
	ev->point = point;
	ev->action = action;
	ev->occurrence = occurrence;
	event_start(ev);

	bucket->ids[bucket->count++] = ev->event_id;
	num_events++;

	return ev->event_id;
}

/*
 * macavity_event_rearm
 *
 * Reinstate a completed or disarmed event: same ID, same configuration,
 * fresh counters.  An event that is already armed is left exactly as it is,
 * counters included, and false is returned.  The caller must have checked
 * that the event exists.
 */
bool
macavity_event_rearm(int32 event_id)
{
	MacavityEvent *ev = event_lookup(event_id);

	Assert(ev != NULL);

	if (ev->state == MACAVITY_EVENT_ARMED)
		return false;

	event_start(ev);
	return true;
}

/*
 * macavity_event_disarm
 *
 * armed -> disarmed.  Returns false, changing nothing, when there is no such
 * event or it is not armed: completed and disarmed events keep their state.
 * The counters are kept either way, so status still shows how far the
 * event got.
 */
bool
macavity_event_disarm(int32 event_id)
{
	MacavityEvent *ev = event_lookup(event_id);

	if (ev == NULL || ev->state != MACAVITY_EVENT_ARMED)
		return false;

	event_stop(ev, MACAVITY_EVENT_DISARMED);
	return true;
}

/*
 * macavity_event_disarm_all
 *
 * Disarm every armed event.  Returns true if at least one changed state.
 */
bool
macavity_event_disarm_all(void)
{
	bool	changed = false;

	for (int32 i = 0; i < num_events; i++)
	{
		if (events[i].state == MACAVITY_EVENT_ARMED)
		{
			event_stop(&events[i], MACAVITY_EVENT_DISARMED);
			changed = true;
		}
	}
	return changed;
}

/*
 * macavity_registry_reset
 *
 * Forget every event and restart ID allocation at 1.  Afterwards the backend
 * is indistinguishable from one that has never created an event.  Returns
 * the number of events discarded.
 */
int32
macavity_registry_reset(void)
{
	int32	discarded = num_events;

	if (registry_cxt != NULL)
		MemoryContextReset(registry_cxt);

	events = NULL;
	num_events = 0;
	max_events = 0;
	memset(buckets, 0, sizeof(buckets));
	xact_skip_pending = false;

	return discarded;
}

/*
 * macavity_event_set_xact_skip
 *
 * Called from the SQL layer, which knows (via IsTransactionBlock()) whether
 * the imminent transaction end belongs to the arming statement.
 */
void
macavity_event_set_xact_skip(int32 event_id)
{
	MacavityEvent *ev = event_lookup(event_id);

	Assert(ev != NULL);
	ev->skip_xact_event = true;
	xact_skip_pending = true;
}

/*
 * macavity_xact_cleanup
 *
 * Called at the end of every transaction.  The pending-skip flags are
 * transient state about a specific transaction and must never leak into the
 * next one; the events themselves deliberately survive, so an event can be
 * armed in one transaction and fire in a later one.
 *
 * xact_skip_pending keeps this free for the common case of no skip having
 * been set in this transaction.
 */
void
macavity_xact_cleanup(void)
{
	if (!xact_skip_pending)
		return;

	for (int32 i = 0; i < num_events; i++)
		events[i].skip_xact_event = false;
	xact_skip_pending = false;
}

/*
 * event_skip_hit
 *
 * True when this hit belongs to the statement or transaction that armed
 * the event and must not be counted.  Each skip is one-shot.
 */
static bool
event_skip_hit(MacavityEvent *ev)
{
	switch (ev->point)
	{
		case MACAVITY_POINT_EXECUTOR_END:
			if (ev->skip_exec_end_depth >= 0 &&
				ev->skip_exec_end_depth == macavity_exec_nesting)
			{
				ev->skip_exec_end_depth = -1;
				return true;
			}
			return false;

		case MACAVITY_POINT_BEFORE_COMMIT:
		case MACAVITY_POINT_BEFORE_ABORT:
			if (ev->skip_xact_event)
			{
				ev->skip_xact_event = false;
				return true;
			}
			return false;

		default:
			return false;
	}
}

void
macavity_event_scan_begin(MacavityPoint point, MacavityEventScan *scan)
{
	scan->point = point;
	scan->rank = 0;
	scan->pos = 0;
}

/*
 * macavity_event_next
 *
 * Continue a walk over the events at scan->point, recording one matching
 * hit on each armed event, and stop at the next one that fires.
 *
 * Order matters here, and it is the whole point of this function:
 *
 *		1. the hit is counted	 (hits++, so remaining falls by one)
 *		2. the threshold is tested
 *		3. the event is marked completed
 *		4. ... and only then does the caller run the action
 *
 * Counting first means the hit is recorded even when the action never
 * returns -- an injected ERROR unwinds past the caller, and 'crash' kills
 * the backend outright.  If the counter were bumped afterwards, the very
 * hit that fired the event would be the one missing from
 * macavity_status().
 *
 * Marking the event completed before the action also makes it reliably
 * one-shot: there is no window in which the error being unwound could
 * re-enter the hook and fire the same event a second time.
 *
 * Events are visited one at a time, each counted immediately before its
 * own action could run.  So when an action does not return, the events
 * after it in firing order are not reached for that hit at all: they are
 * neither counted nor fired, exactly as if the fault point had never been
 * reached a second time.
 *
 * Completed is not the same as disarmed: both stop the event firing, but
 * the registry keeps the configuration and counters of either, so the
 * caller can confirm afterwards what happened.
 */
bool
macavity_event_next(MacavityEventScan *scan, MacavityAction *action)
{
	while (scan->rank < MACAVITY_NUM_ACTIONS)
	{
		MacavityBucket *bucket = 	&buckets[scan->point][action_precedence[scan->rank]];

		while (scan->pos < bucket->count)
		{
			MacavityEvent *ev = event_lookup(bucket->ids[scan->pos++]);

			if (ev == NULL || ev->state != MACAVITY_EVENT_ARMED)
				continue;
			if (event_skip_hit(ev))
				continue;

			/* 1. record the hit, before anything can stop us doing so */
			ev->hits++;

			/* 2. not this one? leave the event armed and keep counting */
			if (ev->hits < ev->occurrence)
				continue;

			/* 3. this is the configured occurrence: complete the event */
			event_stop(ev, MACAVITY_EVENT_COMPLETED);

			/* 4. the caller runs this once we return */
			*action = ev->action;
			return true;
		}

		scan->rank++;
		scan->pos = 0;
	}

	return false;
}
