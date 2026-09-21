# Testing Patterns

Ready-made patterns for common tests. Every one was run against a real
cluster while writing this page. Run them on a **test** cluster only.

---

:::{tip}
**Tear down by disconnecting.** The registry dies with the session, so
closing the connection is the one cleanup that can never itself be hit by
an armed event. Within a session, `macavity_reset()` works too, as long as
nothing is still due at `executor_start`. See the
{ref}`FAQ <faq-reset-error>`.
:::

---

## Make a Commit Fail Once, then Succeed

Tests retry logic around commits. In autocommit mode the arming statement's
own commit is skipped, so the **next** statement's commit is the hit:

```text
=# CREATE TABLE orders(id int);
=# SELECT macavity_arm('before_commit', 'error');
=# INSERT INTO orders VALUES (42);      -- fails at commit, rolled back
ERROR:  macavity: injected error at fault point "before_commit"
=# INSERT INTO orders VALUES (42);      -- the retry commits
INSERT 0 1
=# SELECT count(*) FROM orders;
 count
-------
     1
```

Inside an explicit transaction, the `COMMIT` of that same transaction is the
hit:

```postgresql
BEGIN;
SELECT macavity_arm('before_commit', 'error');
INSERT INTO orders VALUES (43);
COMMIT;      -- ERROR: macavity: injected error at fault point "before_commit"
```

To fail the first two commits and let the third through, arm two events:

```postgresql
SELECT macavity_arm_error('before_commit', 1), macavity_arm_error('before_commit', 2);
```

Both see the first commit. Event 1 fires and stops the walk, so event 2 is
not counted for that hit. The second commit is then event 2's hit 1, not
hit 2, so it would fire on the *third* commit. For "fail N in a row", arm
one `occurrence 1` event per failure instead:

```postgresql
SELECT macavity_arm_error('before_commit'), macavity_arm_error('before_commit');
-- commit 1: event 1 fires; commit 2: event 2 fires; commit 3 succeeds
```

---

## Drive a Test from Application Code

A pytest-style test with [psycopg 3](https://www.psycopg.org/psycopg3/),
checking that `save_order()` retries a failed commit:

```python
import psycopg
from psycopg import errors

def save_order(conn, order_id, attempts=3):
    """Code under test: retries a failed commit."""
    for attempt in range(1, attempts + 1):
        try:
            with conn.transaction():
                conn.execute("INSERT INTO orders VALUES (%s)", (order_id,))
            return attempt
        except errors.RaiseException:          # SQLSTATE P0001
            continue
    raise RuntimeError("gave up")

def test_save_order_retries_failed_commit():
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("DELETE FROM orders")
        conn.execute("SELECT macavity_arm('before_commit', 'error')")

        assert save_order(conn, 7) == 2        # first commit failed, retry won
        assert conn.execute("SELECT count(*) FROM orders").fetchone()[0] == 1

        hits, state = conn.execute(
            "SELECT hits, state FROM macavity_status() WHERE event_id = 1"
        ).fetchone()
        assert (hits, state) == (1, "completed")
    # closing the connection discards the session's registry
```

The fault must be armed on **the same connection** as the code under test,
because events are session-local. With a connection pool, check a
connection out, arm on it, and hand that connection to the code under test.

---

## Fail the Nth Statement

Useful for finding the step in a migration or batch job that is not safely
restartable:

```postgresql
SELECT macavity_arm('executor_start', 'error', 4);
-- then, in the same psql session:   \i migration.sql
-- the script's 4th executor query fails
```

Only statements that go through the executor count. DDL, `BEGIN`, `SET` and
other utility statements do not, while queries run inside functions do. See
[what produces executor hits](architecture.md#what-produces-executor-hits). To
find the right N, arm a harmless event with a large occurrence, run the
script, and read `hits`:

```postgresql
SELECT macavity_arm('executor_start', 'delay', 1000000);
-- run the script in the same session:   \i migration.sql
SELECT hits - 1 AS executor_queries FROM macavity_status();   -- minus the status query
```

---

## Fail in the Middle of a PL/pgSQL Function

Queries inside functions reach the executor points too, so an event can
fire partway through a function. That is handy for testing that a
function's exception handler, or its caller, copes:

```postgresql
CREATE FUNCTION transfer() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE accounts SET balance = balance - 10 WHERE id = 1;   -- hit 2
    UPDATE accounts SET balance = balance + 10 WHERE id = 2;   -- hit 3
END $$;

SELECT macavity_arm('executor_start', 'error', 3);
SELECT transfer();   -- hit 1 is this SELECT; the second UPDATE fails
```

The whole statement fails, so the first `UPDATE` is rolled back with it.

---

## Hold Locks Longer to Test Timeouts

A `delay` at `before_commit` keeps a transaction's locks for an extra
second, which makes lock-wait behaviour in another session easy to
reproduce.

Session A:

```postgresql
BEGIN;
UPDATE accounts SET balance = balance - 10 WHERE id = 1;
SELECT macavity_arm('before_commit', 'delay');
COMMIT;                     -- sleeps 1 s before committing, row still locked
```

Session B, started during A's `COMMIT`:

```text
=# SET lock_timeout = '200ms';
=# UPDATE accounts SET balance = balance + 10 WHERE id = 1;
ERROR:  canceling statement due to lock timeout
```

---

## Check `statement_timeout` Handling

`delay` honours cancellation outside abort processing, so it is a quick way
to make a statement time out on demand:

```text
=# SET statement_timeout = '200ms';
=# SELECT macavity_arm('executor_start', 'delay');
=# SELECT 'x';
ERROR:  canceling statement due to statement timeout
```

---

## Verify Atomicity across a Crash

:::{danger}
This crashes the backend, and PostgreSQL restarts every session on the
cluster.
:::

```text
=# CREATE TABLE ledger(id int);
=# INSERT INTO ledger VALUES (1);            -- committed
=# BEGIN;
=# INSERT INTO ledger VALUES (2);
=# SELECT macavity_arm_crash('before_commit');
=# COMMIT;
server closed the connection unexpectedly

-- reconnect once the server has recovered
=# SELECT * FROM ledger;
 id
----
  1
=# SELECT count(*) FROM macavity_status();   -- new session, empty registry
 count
-------
     0
```

The crash happened before the commit record was written, so row 2 never
existed, and row 1 survived crash recovery.

To crash *after* a commit instead, arm `crash` at `executor_start` as the
last statement before `COMMIT`. `COMMIT` is not an executor hit, so the
first statement after it is the one that crashes, and the committed rows
must survive.

---

## Slow Down Abort Processing

Code that cleans up in abort callbacks (your own extension's, or a pooler's
reaction to a slow rollback) can be exercised with a `delay` at
`before_abort`:

```postgresql
SELECT macavity_arm('before_abort', 'delay');
BEGIN;
SELECT 1 / (random() * 0)::int;   -- error: the transaction is now aborted
ROLLBACK;                          -- the abort already happened; see below
```

The abort runs when the error is raised, so the second of delay happens
there, not at `ROLLBACK`. Remember that `ROLLBACK TO SAVEPOINT` and caught
PL/pgSQL exceptions are **not** `before_abort` hits. See
{ref}`before_abort <before-abort>`.
