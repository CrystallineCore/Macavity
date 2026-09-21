# Quick Start Tutorial

Your first injected faults in five minutes. Use `psql` against a
**throwaway** cluster where `CREATE EXTENSION macavity` has been run. Output
is trimmed to the interesting lines.

---

## Step 1: See What Can Be Armed

```text
=# SELECT * FROM macavity_points();
     point      |                                    description
----------------+------------------------------------------------------------------------------------
 executor_start | before executor execution begins (ExecutorStart_hook)
 executor_end   | after executor execution completes (ExecutorEnd_hook)
 before_commit  | before transaction commit processing (XACT_EVENT_PRE_COMMIT)
 before_abort   | during top-level transaction abort, not subtransaction rollback (XACT_EVENT_ABORT)
```

---

## Step 2: Fail the Next Statement

```text
=# SELECT macavity_arm('executor_start', 'error');
 macavity_arm
--------------
            1

=# SELECT 1;
ERROR:  macavity: injected error at fault point "executor_start"
```

`macavity_arm()` returned `1`, the new event's **ID**. The next statement's
`ExecutorStart` was the first matching hit, so the event fired.

---

## Step 3: Inspect the Evidence

```text
=# SELECT * FROM macavity_status();
 event_id |     point      | action | occurrence | hits | remaining |   state
----------+----------------+--------+------------+------+-----------+-----------
        1 | executor_start | error  |          1 |    1 |         0 | completed
```

The event is `completed`: it fired and will not fire again. The hit was
counted *before* the error was raised, so `hits` is 1 even though the
statement failed.

---

## Step 4: Reinstate the Event

```text
=# SELECT macavity_arm(1);
 macavity_arm
--------------
 t

=# SELECT 2;
ERROR:  macavity: injected error at fault point "executor_start"
```

`macavity_arm(event_id)` puts a completed or disarmed event back to `armed`
with fresh counters. Armed again means it fires again: the very next
statement, whatever it is, is the matching hit.

:::{important}
While an `executor_start` or `executor_end` event is armed, **every query
counts**, including `macavity_status()`, `macavity_disarm()` and
`macavity_reset()` themselves. Had we run `SELECT macavity_reset();`
instead of `SELECT 2;`, the reset would have received the error. See the
{ref}`FAQ <faq-reset-error>`.
:::

---

## Step 5: Count to N

```text
=# SELECT macavity_arm('executor_start', 'error', 3);
 macavity_arm
--------------
            2

=# SELECT 'one';      -- hit 1
=# SELECT 'two';      -- hit 2
=# SELECT 'three';    -- hit 3
ERROR:  macavity: injected error at fault point "executor_start"
```

---

## Step 6: Fail a Commit

```text
=# CREATE TEMP TABLE orders(id int);
=# BEGIN;
=# SELECT macavity_arm('before_commit', 'error');
=# INSERT INTO orders VALUES (1);
=# COMMIT;
ERROR:  macavity: injected error at fault point "before_commit"
=# SELECT count(*) FROM orders;
 count
-------
     0
```

The transaction rolled back, so the `INSERT` is gone.

---

## Step 7: Delay Instead of Failing

```text
=# \timing on
=# SELECT macavity_arm_delay('executor_start');
=# SELECT 'slow';
Time: 1001.472 ms (00:01.001)
```

`delay` sleeps for one second and then lets the statement run normally.

---

## Step 8: Several Events at Once

```text
=# SELECT macavity_arm_delay('executor_start', 2),
          macavity_arm_error('executor_start', 5),
          macavity_arm_crash('before_commit', 10);

=# SELECT event_id, point, action, occurrence, hits, state
     FROM macavity_status() WHERE state = 'armed';
 event_id |     point      | action | occurrence | hits | state
----------+----------------+--------+------------+------+-------
        5 | executor_start | delay  |          2 |    1 | armed
        6 | executor_start | error  |          5 |    1 | armed
        7 | before_commit  | crash  |         10 |    0 | armed
```

The status query itself was hit 1 of both `executor_start` events. Each
event counts independently.

:::{warning}
Event 7 counts **every** commit, and in autocommit mode every statement
commits, including these `SELECT`s. Its 10th commit will crash the backend,
so move on to Step 9 rather than experimenting here.
:::

---

## Step 9: Clean Up

```text
=# SELECT macavity_disarm();      -- hit 2 of event 5: delayed 1 s, then disarms all
 macavity_disarm
-----------------
 t
=# SELECT macavity_reset();
 macavity_reset
----------------
              7
```

`macavity_disarm()` with no argument disarms every armed event, and
`macavity_reset()` forgets every event and restarts IDs at 1. Disconnecting
works too, because the registry dies with the session.

---

## Best Practices

### ✅ DO:
- Arm on **the same connection** that runs the code under test
- Check `macavity_status()` afterwards to confirm the fault really fired
- Use `delay` with a huge occurrence to measure how many hits a piece of code produces
- Tear down by disconnecting, which nothing can interfere with

### ❌ DON'T:
- Install macavity on any cluster you care about
- Grant `macavity_arm_crash()` or the generic `macavity_arm()` to roles that shouldn't restart the cluster
- Forget that macavity's own function calls are executor hits too
- Expect `before_abort` to fire on `ROLLBACK TO SAVEPOINT`

---

## Next Steps

- **[Architecture](architecture.md)**: exactly what counts as a hit, and why
- **[Testing Patterns](patterns.md)**: retry testing, timeouts, crash recovery
- **[API Reference](api.md)**: every function in detail
