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

-- The arming statement fails after arming executor_end.  Its ExecutorEnd
-- never runs, so the skip reserved for it must not survive and swallow a
-- later hit: with occurrence 2 the event fires at stmt_b, not stmt_c.
-- (random() * 0 keeps the division from being folded at plan time, which
-- would fail the statement before macavity_arm() ran at all.)
SELECT macavity_arm('executor_end', 'error', 2), 1 / (random() * 0)::int;
SELECT 'stmt_a' AS stmt;
SELECT 'stmt_b' AS stmt;
SELECT 'stmt_c' AS stmt;
SELECT event_id, hits, state FROM macavity_status();
SELECT macavity_reset();

-- same, inside an explicit transaction block that is then rolled back
BEGIN;
SELECT macavity_arm('executor_end', 'error', 2), 1 / (random() * 0)::int;
ROLLBACK;
SELECT 'stmt_a' AS stmt;
SELECT 'stmt_b' AS stmt;
SELECT 'stmt_c' AS stmt;
SELECT macavity_reset();

-- same, inside a PL/pgSQL exception block: no transaction abort happens,
-- only a subtransaction rollback, and the skip must still be dropped
DO $$
BEGIN
	BEGIN
		PERFORM macavity_arm('executor_end', 'error', 2), 1 / (random() * 0)::int;
	EXCEPTION WHEN division_by_zero THEN NULL;
	END;
	PERFORM 'a';
	RAISE NOTICE 'after stmt_a';
	PERFORM 'b';
	RAISE NOTICE 'after stmt_b: not reached';
END $$;
SELECT event_id, hits, state FROM macavity_status();
SELECT macavity_reset();

-- but an error inside the arming statement that does not kill it keeps the
-- skip: the outer SELECT armed the event, caught an error in a nested
-- block, and finished normally, so its own ExecutorEnd is still skipped and
-- the next statement is the matching hit
CREATE FUNCTION macavity_test_arm_then_catch() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
	id integer;
BEGIN
	BEGIN
		id := macavity_arm('executor_end', 'error');
		PERFORM 1 / (random() * 0)::int;
	EXCEPTION WHEN division_by_zero THEN NULL;
	END;
	RETURN id;
END $$;
SELECT macavity_test_arm_then_catch();
SELECT 1 AS statement_whose_end_fails;
SELECT event_id, hits, state FROM macavity_status();
DROP FUNCTION macavity_test_arm_then_catch();
SELECT macavity_reset();

-- before_abort fires only when a whole transaction aborts.  Rolling back a
-- subtransaction -- ROLLBACK TO SAVEPOINT, or a PL/pgSQL exception block
-- catching an error -- is not a matching hit; the top-level ROLLBACK is.
BEGIN;
SELECT macavity_arm('before_abort', 'delay');
SAVEPOINT sp;
SELECT 1 / (random() * 0)::int;
ROLLBACK TO SAVEPOINT sp;
SELECT hits, state FROM macavity_status();
DO $$
BEGIN
	PERFORM 1 / (random() * 0)::int;
EXCEPTION WHEN division_by_zero THEN NULL;
END $$;
SELECT hits, state FROM macavity_status();
ROLLBACK;
SELECT hits, state FROM macavity_status();
SELECT macavity_reset();
