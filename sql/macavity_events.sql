--
-- macavity: the event registry -- several events at once.
--
-- Every status query is itself a matching hit for executor_start (before
-- it reads the registry) and executor_end (after it has), and its implicit
-- commit is a hit for before_commit.  The expected counters below include
-- those hits.
--
SELECT macavity_reset();

--
-- Creation: IDs are backend-local integers handed out 1, 2, 3, ... across
-- every arming function, and each event starts armed with fresh counters.
--
SELECT macavity_arm('executor_start', 'delay', 1000) AS first,
	   macavity_arm('executor_start', 'error', 1000) AS second,
	   macavity_arm('before_commit', 'crash', 1000) AS third;
SELECT macavity_arm_delay('executor_end', 1000) AS fourth;
SELECT event_id, point, action, occurrence, state FROM macavity_status();

-- IDs are never reused while the registry lives: disarming does not free one.
SELECT macavity_disarm();
SELECT macavity_arm_error('executor_start', 1000) AS fifth;

-- Reset forgets everything, and the next event is 1 again.  An event armed
-- before the reset never fires afterwards.
SELECT macavity_arm_error('executor_start', 2) AS sixth;
SELECT macavity_reset();
SELECT 1 AS would_have_been_hit_two;
SELECT * FROM macavity_status();
SELECT macavity_arm_error('executor_start', 1000) AS first_again;
SELECT macavity_reset();

--
-- Several events at the same point keep independent counters.  Both are
-- 'error', so when both are due at the same hit the lower ID goes first --
-- and, since an error does not return, the other one is not reached at all
-- for that hit.
--
SELECT macavity_arm_error('executor_start', 3) AS a,
	   macavity_arm_error('executor_start', 5) AS b;
SELECT 1 AS hit_one;
SELECT event_id, hits, remaining, state FROM macavity_status();	-- hit two
SELECT 3 AS hit_three_fails;			-- event 1 fires; event 2 not reached
SELECT event_id, hits, remaining, state FROM macavity_status();	-- event 2: hit three
SELECT 4 AS hit_four;
SELECT 5 AS hit_five_fails;				-- event 2 fires
SELECT * FROM macavity_status();
SELECT macavity_reset();

--
-- Events at different points count only their own point's hits.
--
BEGIN;
SELECT macavity_arm_error('executor_start', 100) AS on_start,
	   macavity_arm_error('executor_end', 100) AS on_end,
	   macavity_arm_error('before_commit', 2) AS on_commit;
SELECT 1 AS statement_one;
SELECT event_id, point, hits, state FROM macavity_status();
COMMIT;									-- before_commit hit 1
BEGIN;
SELECT event_id, point, hits, state FROM macavity_status();
ROLLBACK;								-- not a commit
BEGIN;
COMMIT;									-- before_commit hit 2: fires
SELECT event_id, point, hits, state FROM macavity_status();
SELECT macavity_reset();

--
-- Lifecycle: every event has its own state, and completed and disarmed
-- events stay in the registry.
--
SELECT macavity_arm_error('executor_start', 1) AS will_complete;
SELECT 1 AS completes_event_1;
SELECT macavity_arm_delay('executor_end', 100) AS will_be_disarmed,
	   macavity_arm_error('before_commit', 100) AS stays_armed,
	   macavity_arm_error('executor_start', 100) AS also_stays_armed;
SELECT macavity_disarm(2);
-- one completed, one disarmed, two armed
SELECT * FROM macavity_status();

-- Disarm changes only armed events: completed, already-disarmed and
-- unknown IDs all report false and change nothing.
SELECT macavity_disarm(1) AS completed,
	   macavity_disarm(2) AS already_disarmed,
	   macavity_disarm(99) AS unknown;
SELECT macavity_disarm(3) AS armed;
SELECT event_id, state FROM macavity_status();

-- Disarm-all changes the remaining armed event, then has nothing left.
SELECT macavity_disarm() AS changed_something;
SELECT macavity_disarm() AS changed_something;
SELECT event_id, state, hits, remaining FROM macavity_status();

-- Reinstating a disarmed event: same ID and configuration, counters reset.
SELECT macavity_arm(4) AS reinstated;
SELECT event_id, point, action, occurrence, hits, remaining, state
  FROM macavity_status() WHERE event_id = 4;

-- Reinstating an event that is already armed changes nothing, not even the
-- counters it has built up: they go on from 3 to 5, counting the
-- reinstating statement and the status query, instead of restarting.
SELECT 1 AS another_hit;
SELECT hits FROM macavity_status() WHERE event_id = 4;				-- 3
SELECT macavity_arm(4) AS reinstated;								-- hit 4
SELECT event_id, hits, remaining, state FROM macavity_status() WHERE event_id = 4;	-- 5
SELECT macavity_disarm(4);

-- Reinstating a completed event makes it eligible to fire again.
SELECT macavity_arm(1) AS reinstated;
SELECT 1 AS event_1_fires_again;
SELECT event_id, hits, remaining, state FROM macavity_status() WHERE event_id = 1;
SELECT macavity_reset();

--
-- Precedence: delay > crash > error, whatever the IDs.  The error event is
-- created first, so it has the lower ID, yet the delay runs before it.  Had
-- the error gone first, it would have aborted the statement before the
-- delay was reached, leaving the delay armed with one hit.
--
SELECT macavity_arm_error('executor_start', 2) AS error_event,
	   macavity_arm_delay('executor_start', 2) AS delay_event;
SELECT clock_timestamp() AS t0 \gset
SELECT 1 AS delayed_then_fails;			-- hit 2: delay, then error
SELECT clock_timestamp() - :'t0'::timestamptz >= interval '0.9 second'
	AS delay_ran_first;
SELECT event_id, action, hits, state FROM macavity_status();
SELECT macavity_reset();

--
-- Equal actions go in ascending event_id order -- ID order, not the order
-- in which the events were (re)armed.  Event 1 is disarmed and reinstated
-- after event 2 exists, and still fires first.
--
BEGIN;
SELECT macavity_arm_error('before_commit') AS e1;
SELECT macavity_disarm(1);
SELECT macavity_arm_error('before_commit') AS e2;
SELECT macavity_arm(1);
COMMIT;									-- event 1 fires; event 2 not reached
BEGIN;
SELECT event_id, hits, remaining, state FROM macavity_status();
ROLLBACK;
BEGIN;
COMMIT;									-- now event 2
SELECT event_id, hits, remaining, state FROM macavity_status();
SELECT macavity_reset();

--
-- Several delay events due at the same hit all run: a delay returns, so
-- evaluation carries on to the next event.
--
SELECT macavity_arm_delay('executor_start') AS d1,
	   macavity_arm_delay('executor_start') AS d2;
SELECT clock_timestamp() - statement_timestamp() >= interval '1.8 seconds'
	AS both_delays_ran;
SELECT event_id, hits, state FROM macavity_status();
SELECT macavity_reset();

--
-- Several error events at one point: only the first due error is reached
-- per hit (above); events that are not due yet are still counted if they
-- come before it in firing order.
--
SELECT macavity_arm_error('executor_start', 2) AS due_second,
	   macavity_arm_error('executor_start', 1) AS due_first,
	   macavity_arm_error('executor_start', 3) AS due_third;
SELECT 1 AS fails_via_event_2;			-- event 1 counted, event 2 fires
SELECT 2 AS fails_via_event_1;			-- event 1 fires, event 3 not reached
SELECT event_id, occurrence, hits, remaining, state FROM macavity_status();
SELECT macavity_reset();

--
-- Different actions and points together.  At COMMIT the before_commit delay
-- runs first, then the before_commit error aborts the transaction, and the
-- abort reaches the before_abort delay: two delays in one COMMIT.  The
-- executor_start event just keeps counting.
--
BEGIN;
SELECT macavity_arm_error('before_commit') AS commit_error,
	   macavity_arm_delay('before_commit') AS commit_delay,
	   macavity_arm_delay('before_abort') AS abort_delay,
	   macavity_arm_error('executor_start', 100) AS bystander;
SELECT clock_timestamp() AS t0 \gset
COMMIT;
SELECT clock_timestamp() - :'t0'::timestamptz >= interval '1.8 seconds'
	AS both_delays_ran;
SELECT * FROM macavity_status();
SELECT macavity_reset();
SELECT * FROM macavity_status();
