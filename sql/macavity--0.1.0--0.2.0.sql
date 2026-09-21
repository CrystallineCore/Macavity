/* macavity/sql/macavity--0.1.0--0.2.0.sql */

-- complain if script is sourced in psql rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION macavity UPDATE TO '0.2.0'" to load this file. \quit

--
-- 0.1.0 -> 0.2.0: the single armed fault becomes a backend-local registry
-- of events.  macavity_arm() now returns the new event's ID,
-- macavity_disarm() takes an optional event ID and returns boolean, and
-- macavity_status() returns one row per event.  Their return types change,
-- so they are dropped and recreated; any GRANTs on them must be reissued.
-- macavity_points() is unchanged.
--
-- No state is carried over: fault state has only ever lived in backend
-- memory.
--
DROP FUNCTION macavity_arm(text, text, integer);
DROP FUNCTION macavity_disarm();
DROP FUNCTION macavity_status();

-- Create a new armed event in the current session and return its ID.
--
--   point       one of macavity_points().point
--   action      'error', 'crash' or 'delay'
--   occurrence  which matching hit fires the event; 1 means the next one.
--               Must be > 0.
--
-- On every matching hit at the event's point, hits is incremented and
-- remaining (occurrence - hits) falls by one.  Those counters are updated
-- BEFORE the configured action runs, so the hit that fires the event is
-- recorded even though the action raises an error or kills the backend.
--
-- When an event fires it becomes 'completed' and stops firing, but stays in
-- macavity_status() with its final counters.  When several armed events
-- meet at one hit they are evaluated in the order delay > crash > error,
-- then ascending event_id.
--
-- 'error' is not accepted at 'before_abort': the transaction is already
-- aborting by the time that point is reached.
CREATE FUNCTION macavity_arm(point text,
							  action text,
							  occurrence integer DEFAULT 1)
RETURNS integer
AS 'MODULE_PATHNAME', 'macavity_arm'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_arm(text, text, integer) IS
'Create a new armed, session-local event and return its event_id; counters are updated before the action runs. DESTRUCTIVE: action ''crash'' SIGKILLs the calling backend, which cannot restore itself.';

-- Reinstate an existing event by ID.  A completed or disarmed event goes
-- back to 'armed' with its original ID and configuration and fresh counters
-- (hits 0, remaining = occurrence).  Returns true if the event was
-- reinstated, false if it was already armed -- in which case it is left
-- untouched, counters included.  An unknown ID is an error.
--
-- A single argument always resolves to this form: creating an event needs
-- at least a point and an action.
CREATE FUNCTION macavity_arm(event_id integer)
RETURNS boolean
AS 'MODULE_PATHNAME', 'macavity_arm_event'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_arm(integer) IS
'Reinstate a completed or disarmed event by event_id, resetting its counters; false if it was already armed.';

-- Action-specific shorthands for macavity_arm(point, '<action>',
-- occurrence).  Same validation, same kind of event; each returns the new
-- event's ID.
CREATE FUNCTION macavity_arm_error(point text,
									occurrence integer DEFAULT 1)
RETURNS integer
AS 'MODULE_PATHNAME', 'macavity_arm_error'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_arm_error(text, integer) IS
'Create a new armed ''error'' event and return its event_id.';

CREATE FUNCTION macavity_arm_delay(point text,
									occurrence integer DEFAULT 1)
RETURNS integer
AS 'MODULE_PATHNAME', 'macavity_arm_delay'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_arm_delay(text, integer) IS
'Create a new armed ''delay'' event and return its event_id.';

CREATE FUNCTION macavity_arm_crash(point text,
									occurrence integer DEFAULT 1)
RETURNS integer
AS 'MODULE_PATHNAME', 'macavity_arm_crash'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_arm_crash(text, integer) IS
'Create a new armed ''crash'' event and return its event_id. DESTRUCTIVE: SIGKILLs the calling backend when it fires.';

-- Disarm one event (by ID) or, with no argument / NULL, every armed event.
-- Disarmed events stay in the registry with their counters.  Returns true
-- if at least one event went from 'armed' to 'disarmed'; completed and
-- already-disarmed events are not changed, and an unknown ID returns false.
CREATE FUNCTION macavity_disarm(event_id integer DEFAULT NULL)
RETURNS boolean
AS 'MODULE_PATHNAME', 'macavity_disarm'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_disarm(integer) IS
'Disarm one armed event, or all armed events when event_id is NULL; true if any event changed state.';

-- Report this session's event registry: one row per event, ordered by
-- event_id, in every state.
--
--   event_id    backend-local ID
--   point       the event's fault point
--   action      'error', 'crash' or 'delay'
--   occurrence  the matching hit that fires the event
--   hits        matching fault-point hits recorded since the event was last
--               armed, counted before the action runs
--   remaining   occurrence - hits; 0 on the hit that fires the event
--   state       'armed', 'completed' or 'disarmed'
--
-- An empty registry returns no rows.
CREATE FUNCTION macavity_status(OUT event_id integer,
								 OUT point text,
								 OUT action text,
								 OUT occurrence integer,
								 OUT hits integer,
								 OUT remaining integer,
								 OUT state text)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'macavity_status'
LANGUAGE C STRICT;

COMMENT ON FUNCTION macavity_status() IS
'Report every event in this session''s macavity registry (event_id, point, action, occurrence, hits, remaining, state), ordered by event_id.';

-- Discard this session's whole event registry and restart event IDs at 1.
-- Returns the number of events discarded.
CREATE FUNCTION macavity_reset()
RETURNS integer
AS 'MODULE_PATHNAME', 'macavity_reset'
LANGUAGE C STRICT;

COMMENT ON FUNCTION macavity_reset() IS
'Discard every event in this session''s macavity registry and restart event IDs at 1; returns the number of events discarded.';

--
-- Safety: arming a fault is a privileged operation.  CREATE EXTENSION would
-- otherwise leave these functions executable by PUBLIC, which would let any
-- user crash their own backend (and, through the postmaster's crash
-- handling, disrupt the cluster).  Grant them explicitly where needed.
--
REVOKE ALL ON FUNCTION macavity_arm(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm_error(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm_delay(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm_crash(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_disarm(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_status() FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_reset() FROM PUBLIC;
