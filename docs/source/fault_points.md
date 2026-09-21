# Fault Points

A fault point is a place in PostgreSQL's execution where macavity can
inject a fault. Each one is built on a documented extension hook or
callback. macavity patches nothing in PostgreSQL core and depends on no
undocumented internals.

`macavity_points()` lists exactly the points the loaded build implements.
Point names are case-sensitive and lowercase.

| Point | PostgreSQL API | Reached |
| --- | --- | --- |
| [`executor_start`](#executor-start) | `ExecutorStart_hook` | Once per executed query, after the executor is initialized and before any tuple is produced |
| [`executor_end`](#executor-end) | `ExecutorEnd_hook` | Once per executed query, after the executor has shut down |
| [`before_commit`](#before-commit) | `RegisterXactCallback`, `XACT_EVENT_PRE_COMMIT` | Once per top-level commit, before the commit record is written |
| [`before_abort`](#before-abort) | `RegisterXactCallback`, `XACT_EVENT_ABORT` | Once per **top-level** transaction abort |

[Architecture](architecture.md#the-arming-skip) explains which hits the
arming statement itself is excluded from, and has a
[table of which statements produce executor hits](architecture.md#what-produces-executor-hits).

(executor-start)=
---

## `executor_start`

Fires **after** PostgreSQL's own `ExecutorStart` has initialized the query,
and before any tuple is produced. Injecting any earlier would leave the
query half-built for no extra test value.

- An `error` here fails the statement before it has read or written
  anything.
- A `delay` here stretches the time before a statement starts doing work,
  while it already holds the locks it acquired during planning and executor
  startup.
- Queries run inside functions (`PERFORM`, `SELECT … INTO`, trigger and
  SQL-function bodies) reach this point too, so an event can fire in the
  middle of a PL/pgSQL function.

(executor-end)=
---

## `executor_end`

Fires **after** PostgreSQL's own `ExecutorEnd` has shut the executor down,
so the point really is "after execution completed".

- For a `SELECT`, the result rows have already been sent to the client
  when the error arrives. Whether the client shows them depends on the
  client: `psql` discards them and shows only the error, while a driver
  reading rows as they stream in may already have processed them.
- For a data-modifying statement, all of its work (including `AFTER`
  triggers) has been done, but the transaction has not committed. An
  `error` rolls that work back.
- The arming statement's own `ExecutorEnd` is not counted. See
  [The Arming Skip](architecture.md#the-arming-skip).

(before-commit)=
---

## `before_commit`

Fires at `XACT_EVENT_PRE_COMMIT`, which runs before the commit record is
written and can still safely raise an error. That makes it the point for
"make this commit fail".

- An `error` here aborts the transaction: `COMMIT` reports the injected
  error and every change in the transaction is rolled back.
- A `delay` here stretches the window between the last statement and the
  commit, while the transaction still holds all of its locks.
- In autocommit mode every statement commits on its own, so every statement
  is a hit, except the arming statement's own commit. Inside
  `BEGIN … COMMIT`, only the `COMMIT` is.
- Two-phase commit (`PREPARE TRANSACTION`) and parallel workers are not
  covered.

(before-abort)=
---

## `before_abort`

Fires at `XACT_EVENT_ABORT`, while a **top-level** transaction is aborting.
That happens on an error outside any savepoint, an explicit `ROLLBACK`, or
a failed `COMMIT`.

PostgreSQL has no pre-abort callback, so by the time this point is reached
the abort is already under way. That has two consequences:

- **`error` is not accepted here.** Raising an error during abort
  processing escalates to `FATAL` and disconnects the session, so
  `macavity_arm()` rejects the combination up front with
  `feature_not_supported`. Use `delay` or `crash`, or arm `error` at
  `before_commit` instead.
- **`delay` here is uninterruptible.** Query cancellation and
  `statement_timeout` cannot be serviced during abort processing, so the
  full second always elapses.

:::{warning}
**`before_abort` does not fire on subtransaction rollback.**

`ROLLBACK TO SAVEPOINT`, a PL/pgSQL `BEGIN … EXCEPTION` block catching an
error, and anything else that rolls back only a subtransaction are **not**
matching hits: a `delay` armed there adds no time, and `hits` does not
move. PostgreSQL reports those through `RegisterSubXactCallback`
(`SUBXACT_EVENT_ABORT_SUB`), which macavity does not hook.

The name means "before the transaction's abort completes", not "before any
rollback". If the enclosing transaction later aborts as a whole, that abort
is a hit as usual.
:::

```text
=# BEGIN;
=# SELECT macavity_arm('before_abort', 'delay');
=# SAVEPOINT sp;
=# SELECT 1 / (random() * 0)::int;
ERROR:  division by zero
=# ROLLBACK TO SAVEPOINT sp;        -- not a hit: returns immediately
=# SELECT hits, state FROM macavity_status();
 hits | state
------+-------
    0 | armed
=# ROLLBACK;                        -- top-level abort: hit, 1 s delay
=# SELECT hits, state FROM macavity_status();
 hits |   state
------+-----------
    1 | completed
```

---

## Not Covered

macavity deliberately claims only what it implements. There are no fault
points for WAL insertion, buffer I/O, locking, networking, background
workers, parallel workers or two-phase commit. For faults deep inside the
server, PostgreSQL 17 and later offer built-in injection points in
specially compiled builds; see the [Tribute](tribute.md). `macavity_points()` reads
straight from the implemented-points table, so a build can never advertise
a point it does not have.
