/* macavity/sql/macavity--0.1.0.sql */

-- complain if script is sourced in psql rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION macavity" to load this file. \quit

--
-- macavity: deterministic, session-local fault injection.
--
-- WARNING: this extension exists to break things on purpose.  The "crash"
-- action terminates the calling backend with SIGKILL.  That connection is
-- gone for good and cannot restore itself, and PostgreSQL responds to any
-- unclean backend exit by terminating the other backends too and running
-- crash recovery -- other clients then see "terminating connection because
-- of crash of another server process".  That is PostgreSQL's crash
-- containment, not macavity state crossing between sessions: a session that
-- never armed anything has no macavity fault, and a session established
-- after the crash starts with nothing armed.  Install on development and
-- test clusters only.
--
-- Fault state is session-local (a backend-local variable) and at most one
-- fault can be armed per session.
--

-- Arm a one-shot fault in the current session.  Returns void, which psql
-- renders as an empty 1x1 result.
--
--   point       one of macavity_points().point
--   action      'error', 'crash' or 'delay'
--   occurrence  which matching event fires the fault; 1 means the next
--               one.  Must be > 0.
--
-- On every matching hit at the armed point, hits is incremented and
-- remaining (occurrence - hits) falls by one.  Those counters are updated
-- BEFORE the configured action runs, so the hit that fires the fault is
-- recorded even though the action raises an error or kills the backend.
--
-- The fault stops being armed as soon as it fires; macavity_status() keeps
-- reporting its final counters until you arm again or call
-- macavity_disarm().  Arming while a fault is already armed is an error.
--
-- 'error' is not accepted at 'before_abort': the transaction is already
-- aborting by the time that point is reached.
CREATE FUNCTION macavity_arm(point text,
							  action text,
							  occurrence integer DEFAULT 1)
RETURNS void
AS 'MODULE_PATHNAME', 'macavity_arm'
LANGUAGE C CALLED ON NULL INPUT;

COMMENT ON FUNCTION macavity_arm(text, text, integer) IS
'Arm a one-shot, session-local fault; counters are updated before the action runs. DESTRUCTIVE: action ''crash'' SIGKILLs the calling backend, which cannot restore itself.';

-- Remove this session's fault, armed or already fired, and reset its
-- counters.  Safe when nothing is armed.  Returns void, which psql renders
-- as an empty 1x1 result.
CREATE FUNCTION macavity_disarm()
RETURNS void
AS 'MODULE_PATHNAME', 'macavity_disarm'
LANGUAGE C STRICT;

COMMENT ON FUNCTION macavity_disarm() IS
'Remove this session''s macavity fault and clear its counters; a no-op when nothing is armed.';

-- Report this session's fault state.  Exactly one row:
--
--   armed       true while the fault is waiting for its occurrence
--   point       the armed point, or the point of the fault that last fired
--   action      'error', 'crash' or 'delay'
--   occurrence  the occurrence that fires the fault
--   hits        matching fault-point hits recorded so far, counted before
--               the action runs
--   remaining   occurrence - hits; 0 on the hit that fires the fault
--
-- After a fault fires, armed is false but the columns above still describe
-- it, so you can confirm the hit was recorded.  When nothing is armed and
-- nothing has fired since the last disarm, armed is false and every other
-- column is NULL.
CREATE FUNCTION macavity_status(OUT armed boolean,
								 OUT point text,
								 OUT action text,
								 OUT occurrence integer,
								 OUT hits integer,
								 OUT remaining integer)
RETURNS record
AS 'MODULE_PATHNAME', 'macavity_status'
LANGUAGE C STRICT;

COMMENT ON FUNCTION macavity_status() IS
'Report this session''s macavity fault state (armed, point, action, occurrence, hits, remaining); after a fault fires, armed is false and the final counters are kept.';

-- List the fault points this build implements.
CREATE FUNCTION macavity_points(OUT point text,
								 OUT description text)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'macavity_points'
LANGUAGE C STRICT;

COMMENT ON FUNCTION macavity_points() IS
'List the fault points supported by this macavity build.';

--
-- Safety: arming a fault is a privileged operation.  CREATE EXTENSION would
-- otherwise leave these functions executable by PUBLIC, which would let any
-- user crash their own backend (and, through the postmaster's crash
-- handling, disrupt the cluster).  Grant them explicitly where needed.
--
REVOKE ALL ON FUNCTION macavity_arm(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_disarm() FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION macavity_points() TO PUBLIC;
