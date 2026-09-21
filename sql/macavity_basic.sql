--
-- macavity: API surface -- points, status, arm/disarm/reset bookkeeping.
--
-- No event may fire in this file: every event armed here uses an
-- occurrence far beyond the number of hits the file produces.  The
-- default occurrence (1) and events that really fire are covered by
-- macavity_faults.sql and macavity_events.sql.
--
CREATE EXTENSION IF NOT EXISTS macavity;

-- Every advertised point must be implemented; this list is the contract.
SELECT point, description FROM macavity_points() ORDER BY point;

-- Nothing created yet: the registry is empty.
SELECT * FROM macavity_status();

-- Arming creates an event and returns its ID.  The occurrence is remembered
-- verbatim.
SELECT macavity_arm('executor_start', 'error', 400);
SELECT event_id, point, action, occurrence, state FROM macavity_status();

-- Arming again creates a second, independent event with the next ID.
SELECT macavity_arm('executor_end', 'delay', 400);
SELECT event_id, point, action, occurrence, state FROM macavity_status();

-- The action-specific forms create events too, and continue the same ID
-- sequence.
SELECT macavity_arm_error('before_commit', 400);
SELECT macavity_arm_delay('before_abort', 400);
SELECT macavity_arm_crash('executor_start', 400);
SELECT event_id, point, action, occurrence, state FROM macavity_status();

-- Disarming everything leaves the events in the registry, disarmed ...
SELECT macavity_disarm();
SELECT event_id, state FROM macavity_status();

-- ... and a second disarm has nothing left to change.
SELECT macavity_disarm();
SELECT macavity_disarm(NULL);

-- Reset forgets every event and restarts IDs at 1.
SELECT macavity_reset();
SELECT * FROM macavity_status();
SELECT macavity_reset();
SELECT macavity_arm('executor_start', 'error', 400);
SELECT macavity_reset();

-- Arming does not count the arming statement itself.  Arm executor_end at
-- a high occurrence and watch the counter: right after arming hits is 0,
-- because the arming statement's own ExecutorEnd was skipped.  Every
-- statement after it -- including each status query -- counts one hit, so
-- the second status query reports 2.
SELECT macavity_arm('executor_end', 'error', 500);
SELECT hits, remaining FROM macavity_status();
SELECT 1 AS first_statement;
SELECT hits, remaining FROM macavity_status();
SELECT macavity_disarm(1);
SELECT event_id, state FROM macavity_status();
SELECT macavity_reset();
