--
-- macavity: hits/remaining semantics.
--
-- The invariant under test: a matching fault-point hit is recorded BEFORE
-- the configured action runs, so the hit that fired the fault is still
-- visible through macavity_status() afterwards.
--
-- before_commit is the point used for counting, because its matching events
-- are transaction ends and this file controls those explicitly.  While a
-- before_commit fault is armed, every status query is therefore wrapped in
-- BEGIN ... ROLLBACK: an abort is not a commit, so reading the counters
-- does not disturb them.  Once a fault has fired, nothing is armed and
-- plain autocommit statements are safe again.
--
-- occurrence = 1: the first matching hit fires.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 1);
SELECT armed, occurrence, hits, remaining FROM macavity_status();	-- 0 / 1
COMMIT;																-- hit 1: fires
-- the hit was counted before the error was raised: hits 1, remaining 0.
-- armed is false now, but the spent fault is still described.
SELECT armed, point, action, occurrence, hits, remaining FROM macavity_status();
SELECT macavity_disarm();

-- occurrence = 2: the first hit only counts; the second fires.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 2);
COMMIT;																-- hit 1
BEGIN;
SELECT armed, hits, remaining FROM macavity_status();				-- 1 / 1
ROLLBACK;
BEGIN;
SELECT 1 AS second_transaction;
COMMIT;																-- hit 2: fires
SELECT armed, point, occurrence, hits, remaining FROM macavity_status();

-- Arming again replaces the spent fault's counters with a fresh 0.
-- occurrence = 3: check hits and remaining after every matching hit.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 3);
SELECT armed, hits, remaining FROM macavity_status();				-- 0 / 3
COMMIT;																-- hit 1
BEGIN;
SELECT armed, hits, remaining FROM macavity_status();				-- 1 / 2
ROLLBACK;
BEGIN;
SELECT 1 AS transaction_two;
COMMIT;																-- hit 2
BEGIN;
SELECT armed, hits, remaining FROM macavity_status();				-- 2 / 1
ROLLBACK;
BEGIN;
SELECT 1 AS transaction_three;
COMMIT;																-- hit 3: fires
SELECT armed, point, action, occurrence, hits, remaining FROM macavity_status();

-- An explicit disarm returns the session to the clear state: armed false
-- and every other column NULL, with no trace of the spent fault.
SELECT macavity_disarm();
SELECT * FROM macavity_status();

-- Events at other points, and aborts, are not matching events and do not
-- move the counters.
BEGIN;
SELECT macavity_arm('before_commit', 'error', 2);
SELECT 1 AS statement_one;
SELECT 1 AS statement_two;
SELECT armed, hits, remaining FROM macavity_status();				-- still 0 / 2
ROLLBACK;															-- an abort, not a hit
BEGIN;
SELECT armed, hits, remaining FROM macavity_status();				-- still 0 / 2
SELECT macavity_disarm();
ROLLBACK;

-- The counters are not transactional: a hit recorded inside a transaction
-- that later rolls back stays recorded.  That is what makes the counters
-- trustworthy after an injected error, which always aborts its transaction.
SELECT macavity_arm('executor_start', 'error', 5);
BEGIN;
SELECT 1 AS hit_inside_doomed_transaction;
ROLLBACK;
-- 2 hits: the rolled-back statement, plus this status query itself
SELECT armed, hits, remaining FROM macavity_status();
SELECT macavity_disarm();
SELECT * FROM macavity_status();
