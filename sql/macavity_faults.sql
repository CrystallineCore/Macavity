--
-- macavity: faults that actually fire.
--
-- Only 'error' and 'delay' are exercised here.  'crash' cannot be tested
-- under pg_regress -- an unclean backend exit makes the postmaster reset
-- the cluster -- so it has its own harness in test/crash_test.sh.
--
-- error at executor_start, next matching hit
SELECT macavity_arm('executor_start', 'error');
SELECT 1 AS never_runs;

-- the event is one-shot: it is completed, and no longer fires.  The hit
-- that fired it was recorded before the error was raised, so the counters
-- are still reported: hits 1, remaining 0.
SELECT * FROM macavity_status();
SELECT 1 AS runs_normally;
SELECT macavity_reset();

-- occurrence counting: hits 1 and 2 pass through, hit 3 fails
SELECT macavity_arm('executor_start', 'error', 3);
SELECT 1 AS hit_one;
SELECT hits, remaining FROM macavity_status();
SELECT 3 AS hit_three_fails;
SELECT state FROM macavity_status();
SELECT macavity_reset();

-- error at executor_end with occurrence 1: the next statement's own
-- ExecutorEnd is the matching hit
SELECT macavity_arm('executor_end', 'error');
SELECT 1 AS statement_whose_end_fails;
-- the hit was recorded before the error: completed, hits 1, remaining 0
SELECT event_id, point, action, occurrence, hits, remaining, state FROM macavity_status();
SELECT macavity_reset();

-- before_commit inside an explicit transaction block: the user's own COMMIT
-- is the matching hit, so the transaction is rolled back instead
BEGIN;
SELECT macavity_arm('before_commit', 'error');
CREATE TEMP TABLE macavity_commit_victim (i int);
INSERT INTO macavity_commit_victim VALUES (1);
COMMIT;
SELECT state FROM macavity_status();
-- the table did not survive the failed commit
SELECT count(*) FROM pg_class WHERE relname = 'macavity_commit_victim';
SELECT macavity_reset();

-- before_commit in autocommit mode: the arming statement's own implicit
-- commit is not counted, so the event survives to trip the next statement
SELECT macavity_arm('before_commit', 'error');
SELECT 1 AS commits_and_then_fails;
SELECT state FROM macavity_status();
SELECT macavity_reset();

-- the same skip applies when a completed event is reinstated in autocommit
-- mode: the reinstating statement's own commit is not counted
SELECT macavity_arm_error('before_commit');
SELECT 1 AS fails_at_commit;
SELECT macavity_arm(1);
SELECT 1 AS fails_again_at_commit;
SELECT event_id, hits, state FROM macavity_status();
SELECT macavity_reset();

-- before_abort during abort processing: the delay runs, then the original
-- error is reported as usual
SELECT macavity_arm('before_abort', 'delay');
DO $$ BEGIN RAISE EXCEPTION 'macavity test: forcing an abort'; END $$;
SELECT state FROM macavity_status();
SELECT macavity_reset();

-- delay really delays: the statement observes at least most of the 1 s
-- sleep between its start and the clock read during execution
SELECT macavity_arm('executor_start', 'delay');
SELECT clock_timestamp() - statement_timestamp() >= interval '0.5 second'
	AS delayed;
SELECT state FROM macavity_status();
SELECT macavity_reset();

-- a disarmed event never fires, however many hits go by
SELECT macavity_arm('executor_start', 'error', 2);
SELECT macavity_disarm(1);
SELECT 1 AS safe_one;
SELECT 2 AS safe_two;
SELECT 3 AS safe_three;
SELECT * FROM macavity_status();
SELECT macavity_reset();
