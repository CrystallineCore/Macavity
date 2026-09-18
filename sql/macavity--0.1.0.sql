/* macavity/sql/macavity--0.1.0.sql */

-- complain if script is sourced in psql rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION macavity" to load this file. \quit

--
-- macavity: deterministic, session-local fault injection.
--
-- WARNING: this extension exists to break things on purpose.  The "crash"
-- action terminates the calling backend with SIGKILL, which makes the
-- postmaster reset the whole cluster and run crash recovery.  Install it on
-- development and test clusters only.
--

-- Arm a one-shot fault in the current session.
--
--   point       one of macavity_points().point
--   action      'error', 'crash' or 'delay'
--   occurrence  which matching event triggers the fault; 1 means the next
--               one.  Must be > 0.
--
-- The fault disarms itself as soon as it triggers.  Arming while a fault is
-- already armed is an error; call macavity_disarm() first.
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
'Arm a one-shot, session-local fault. DESTRUCTIVE: action ''crash'' SIGKILLs the calling backend.';

-- Remove this session's armed fault.  Safe when nothing is armed.
CREATE FUNCTION macavity_disarm()
RETURNS void
AS 'MODULE_PATHNAME', 'macavity_disarm'
LANGUAGE C STRICT;

COMMENT ON FUNCTION macavity_disarm() IS
'Remove this session''s armed macavity fault; a no-op when nothing is armed.';

-- Describe this session's armed fault.  Exactly one row.  When nothing is
-- armed, armed is false and the remaining columns are NULL.
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
'Report this session''s armed macavity fault (armed, point, action, occurrence, hits, remaining).';

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
