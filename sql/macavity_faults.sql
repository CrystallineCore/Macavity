--
-- macavity: faults that actually fire.
--
-- Only 'error' and 'delay' are exercised here.  'crash' cannot be tested
-- under pg_regress -- an unclean backend exit makes the postmaster reset
-- the cluster -- so it has its own harness in test/crash_test.sh.
--
-- error at executor_start, next matching event
SELECT macavity_arm('executor_start', 'error');
SELECT 1 AS never_runs;

-- the fault is one-shot: it is spent, so armed is false.  The hit that
-- fired it was recorded before the error was raised, so the counters are
-- still reported: hits 1, remaining 0.
SELECT * FROM macavity_status();
SELECT 1 AS runs_normally;
SELECT macavity_disarm();

-- occurrence counting: events 1 and 2 pass through, event 3 fails
SELECT macavity_arm('executor_start', 'error', 3);
SELECT 1 AS event_one;
SELECT hits, remaining FROM macavity_status();
SELECT 3 AS event_three_fails;
SELECT armed FROM macavity_status();

-- error at executor_end with occurrence 1: the next statement's own
-- ExecutorEnd is the matching hit
SELECT macavity_arm('executor_end', 'error');
SELECT 1 AS statement_whose_end_fails;
-- the hit was recorded before the error: fired, hits 1, remaining 0
SELECT armed, point, action, occurrence, hits, remaining FROM macavity_status();
SELECT macavity_disarm();
SELECT armed FROM macavity_status();

-- before_commit inside an explicit transaction block: the user's own COMMIT
-- is the matching event, so the transaction is rolled back instead
BEGIN;
SELECT macavity_arm('before_commit', 'error');
CREATE TEMP TABLE macavity_commit_victim (i int);
INSERT INTO macavity_commit_victim VALUES (1);
COMMIT;
SELECT armed FROM macavity_status();
-- the table did not survive the failed commit
SELECT count(*) FROM pg_class WHERE relname = 'macavity_commit_victim';

-- before_commit in autocommit mode: the arming statement's own implicit
-- commit is not counted, so the fault survives to trip the next statement
SELECT macavity_arm('before_commit', 'error');
SELECT 1 AS commits_and_then_fails;
SELECT armed FROM macavity_status();

-- before_abort during abort processing: the delay runs, then the original
-- error is reported as usual
SELECT macavity_arm('before_abort', 'delay');
DO $$ BEGIN RAISE EXCEPTION 'macavity test: forcing an abort'; END $$;
SELECT armed FROM macavity_status();

-- delay really delays: the statement observes at least most of the 1 s
-- sleep between its start and the clock read during execution
SELECT macavity_arm('executor_start', 'delay');
SELECT clock_timestamp() - statement_timestamp() >= interval '0.5 second'
	AS delayed;
SELECT armed FROM macavity_status();

-- a disarmed fault never fires, however many events go by
SELECT macavity_arm('executor_start', 'error', 2);
SELECT macavity_disarm();
SELECT 1 AS safe_one;
SELECT 2 AS safe_two;
SELECT 3 AS safe_three;
SELECT * FROM macavity_status();
