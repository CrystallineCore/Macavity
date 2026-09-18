--
-- macavity: API surface -- points, status, arm/disarm bookkeeping.
--
-- No fault may fire in this file: every fault armed here uses an
-- occurrence far beyond the number of events the file produces.  The
-- default occurrence (1) and faults that really fire are covered by
-- macavity_faults.sql.
--
CREATE EXTENSION IF NOT EXISTS macavity;

-- Every advertised point must be implemented; this list is the contract.
SELECT point, description FROM macavity_points() ORDER BY point;

-- Nothing armed yet: armed is false, everything else NULL.
SELECT * FROM macavity_status();

-- Arming reports through status().  The occurrence is remembered verbatim.
SELECT macavity_arm('executor_start', 'error', 400);
SELECT armed, point, action, occurrence FROM macavity_status();

-- Arming again is refused rather than silently replacing the armed fault.
SELECT macavity_arm('executor_end', 'delay');
SELECT armed, point, action, occurrence FROM macavity_status();

-- Disarm returns us to the empty state ...
SELECT macavity_disarm();
SELECT * FROM macavity_status();

-- ... and is a no-op when nothing is armed.
SELECT macavity_disarm();
SELECT macavity_disarm();
SELECT armed FROM macavity_status();

-- Arming does not count the arming statement itself.  Arm executor_end at
-- a high occurrence and watch the counter: right after arming hits is 0,
-- because the arming statement's own ExecutorEnd was skipped.  Every
-- statement after it -- including each status query -- counts one event, so
-- the second status query reports 2.
SELECT macavity_arm('executor_end', 'error', 500);
SELECT hits, remaining FROM macavity_status();
SELECT 1 AS first_statement;
SELECT hits, remaining FROM macavity_status();
SELECT macavity_disarm();
SELECT armed FROM macavity_status();
