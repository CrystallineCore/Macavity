--
-- macavity: hits/remaining semantics.
--
-- The invariant under test: a matching fault-point hit is recorded BEFORE
-- the configured action runs, so the hit that fired the event is still
-- visible through macavity_status() afterwards.
--
-- before_commit is the point used for counting, because its matching hits
-- are transaction ends and this file controls those explicitly.  While a
-- before_commit event is armed, every status query is therefore wrapped in
-- BEGIN ... ROLLBACK: an abort is not a commit, so reading the counters
-- does not disturb them.  Once the event has fired, nothing is armed and
-- plain autocommit statements are safe again.
--
-- occurrence = 1: the first matching hit fires.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 1);
SELECT state, occurrence, hits, remaining FROM macavity_status();	-- 0 / 1
COMMIT;																-- hit 1: fires
-- the hit was counted before the error was raised: hits 1, remaining 0.
-- the event is completed now, and still described in full.
SELECT * FROM macavity_status();
SELECT macavity_reset();

-- occurrence = 2: the first hit only counts; the second fires.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 2);
COMMIT;																-- hit 1
BEGIN;
SELECT state, hits, remaining FROM macavity_status();				-- 1 / 1
ROLLBACK;
BEGIN;
SELECT 1 AS second_transaction;
COMMIT;																-- hit 2: fires
SELECT event_id, point, occurrence, hits, remaining, state FROM macavity_status();

-- Reinstating the completed event by ID starts its counters again from 0,
-- with the same ID and configuration.  Watch them after every hit of a
-- second run to completion.
BEGIN;
SELECT macavity_arm(1);
SELECT event_id, state, hits, remaining FROM macavity_status();		-- 0 / 2
COMMIT;																-- hit 1
BEGIN;
SELECT state, hits, remaining FROM macavity_status();				-- 1 / 1
ROLLBACK;
BEGIN;
SELECT 1 AS second_run;
COMMIT;																-- hit 2: fires
SELECT event_id, occurrence, hits, remaining, state FROM macavity_status();
SELECT macavity_reset();

-- occurrence = 3: check hits and remaining after every matching hit.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 3);
SELECT state, hits, remaining FROM macavity_status();				-- 0 / 3
COMMIT;																-- hit 1
BEGIN;
SELECT state, hits, remaining FROM macavity_status();				-- 1 / 2
ROLLBACK;
BEGIN;
SELECT 1 AS transaction_two;
COMMIT;																-- hit 2
BEGIN;
SELECT state, hits, remaining FROM macavity_status();				-- 2 / 1
ROLLBACK;
BEGIN;
SELECT 1 AS transaction_three;
COMMIT;																-- hit 3: fires
SELECT * FROM macavity_status();

-- A reset returns the session to an empty registry, with no trace of the
-- completed event.
SELECT macavity_reset();
SELECT * FROM macavity_status();

-- Events at other points, and aborts, are not matching hits and do not
-- move the counters.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 2);
SELECT 1 AS statement_one;
SELECT 1 AS statement_two;
SELECT state, hits, remaining FROM macavity_status();				-- still 0 / 2
ROLLBACK;															-- an abort, not a hit
BEGIN;
SELECT state, hits, remaining FROM macavity_status();				-- still 0 / 2
SELECT macavity_disarm(1);
ROLLBACK;

-- A disarmed event keeps the counters it had reached ...
BEGIN;
SELECT macavity_arm(1);
COMMIT;																-- hit 1
BEGIN;
SELECT macavity_disarm(1);
ROLLBACK;
SELECT event_id, state, hits, remaining FROM macavity_status();		-- 1 / 1
-- ... until it is reinstated, which resets them.
BEGIN;
SELECT macavity_arm(1);
SELECT event_id, state, hits, remaining FROM macavity_status();		-- 0 / 2
SELECT macavity_disarm(1);
ROLLBACK;
SELECT macavity_reset();

-- The counters are not transactional: a hit recorded inside a transaction
-- that later rolls back stays recorded.  That is what makes the counters
-- trustworthy after an injected error, which always aborts its transaction.
SELECT macavity_arm('executor_start', 'error', 5);
BEGIN;
SELECT 1 AS hit_inside_doomed_transaction;
ROLLBACK;
-- 2 hits: the rolled-back statement, plus this status query itself
SELECT state, hits, remaining FROM macavity_status();
SELECT macavity_reset();
SELECT * FROM macavity_status();
