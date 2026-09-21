# Frequently Asked Questions

Common questions and answers about macavity.

---

## General Questions

### What is macavity?

A PostgreSQL extension for deterministic, session-local fault injection. A
session arms events (an `error`, a `delay` or a `crash`) at one of four
execution points, and each event fires on exactly the Nth matching hit.

---

### Can I use macavity in production?

**No.** macavity exists to break PostgreSQL on purpose. Any role that can
arm `crash` can force the whole cluster through crash recovery, and even
`error` and `delay` events make statements fail or stall by design. Use it
on development and test clusters only.

---

### Does macavity need `shared_preload_libraries` or a restart?

No. It allocates no shared memory and loads on first use after
`CREATE EXTENSION`. `session_preload_libraries = 'macavity'` is optional.

---

### Which PostgreSQL versions and platforms are supported?

PostgreSQL 16, 17 and 18 are tested on Linux. Later majors and other
Unix-likes are expected to work but are untested. Windows is not supported,
and `crash` is refused there. See
[Installation](installation.md#tested-versions-and-platforms).

---

### Can one session's events affect another session?

Not through macavity: each backend has its own registry. The one exception
is PostgreSQL's reaction to a `crash`. Any unclean backend exit makes the
postmaster disconnect **every** session and run crash recovery.

---

### Does keeping it loaded slow things down?

Not measurably. `pgbench` throughput is unchanged, and each armed event at
the point being hit costs about 2.5 ns per hit. See
[Performance & Overhead](performance.md).

---

### How is this different from PostgreSQL's injection points?

Injection points (PostgreSQL 17+) reach deep into core code but need a
specially compiled server. macavity works on stock packaged PostgreSQL but
only at four boundary points. See the [Tribute](tribute.md).

---

## Counting and Timing

(faq-reset-error)=
### Why did my `macavity_reset()` get the injected error?

While an `executor_start` or `executor_end` event is armed, every query is
a hit, including calls to macavity's own functions. If the event is due,
the cleanup call *is* the matching hit:

```text
=# SELECT macavity_arm('executor_start', 'error');
=# SELECT macavity_reset();
ERROR:  macavity: injected error at fault point "executor_start"
```

The event is now `completed`, so running the same call again works. To
avoid it, disconnect instead (the registry dies with the session), or
`macavity_disarm()` first when the event is not due on that hit.

---

### Why did my event fire one statement earlier than I expected?

Usually a statement you did not think of as a query was one:

- `macavity_status()`, `macavity_disarm()` and every other macavity call are
  `SELECT`s
- `EXPLAIN` (without `ANALYZE`) starts and ends the executor
- queries inside functions, triggers and `DO` blocks each count

Arm a `delay` with a huge occurrence, run the code, and read `hits`. See
[What Produces Executor Hits](architecture.md#what-produces-executor-hits).

---

### Why did my event fire one statement later than I expected?

- Utility statements (`BEGIN`, `COMMIT`, DDL, `SET`, `CALL` with an empty
  body) are not executor hits.
- PL/pgSQL fast-path expressions such as `a := 1 + 1` are not executor hits.
- With several events due at one hit, only the first `error` or `crash` in
  [firing order](architecture.md#several-events-at-one-hit) is reached. The
  later ones are not counted for that hit.

:::{note}
Earlier builds had a bug with the same symptom. If the statement that armed
an `executor_end` event failed after arming, the skip reserved for its own
`ExecutorEnd` leaked and swallowed the next legitimate hit. It is fixed;
see the [Changelog](changelog.md).
:::

---

### Why didn't my `before_commit` event fire on the arming statement?

By design. In autocommit mode the arming statement's own commit is skipped,
so arming an event cannot trigger it. The next statement's commit is hit 1.
Inside `BEGIN … COMMIT`, the block's `COMMIT` counts. See
[The Arming Skip](architecture.md#the-arming-skip).

---

### Why didn't `before_abort` fire on `ROLLBACK TO SAVEPOINT`?

By design. `before_abort` is reached only when a **top-level** transaction
aborts. Savepoint rollbacks and caught PL/pgSQL exceptions roll back a
subtransaction and are not hits. See
{ref}`before_abort <before-abort>`.

---

### Why did `before_abort` fire at the error instead of at my `ROLLBACK`?

Inside a transaction block, PostgreSQL aborts the transaction as soon as the
error is raised. The `ROLLBACK` you type afterwards only finishes cleaning
up, so the hit (and any `delay`) happens on the statement that failed.

---

### Why was my `delay` cut short?

Outside abort processing, `delay` sleeps on the process latch, so
`statement_timeout`, query cancellation (Ctrl-C, `pg_cancel_backend()`)
and `pg_terminate_backend()` interrupt it. Only at `before_abort` is it
uninterruptible.

---

### Can I change the delay duration?

Not yet: it is fixed at 1 second. `occurrence` is the last argument of
every arming function, so a future version can add a `duration` argument
without breaking existing calls. Until then, arm several `delay` events at
the same point to stack them.

---

## Errors and Setup

### `permission denied for function macavity_arm`

All functions except `macavity_points()` are revoked from `PUBLIC`. Grant
them to your test role; see [Grant Access](installation.md#grant-access).

---

### `unrecognized fault point "EXECUTOR_START"`

Point and action names are lowercase and case-sensitive. The error's hint
lists the valid names.

---

### `event 1 does not exist in this session`

IDs are per session and restart after `macavity_reset()`. An ID from
another connection, or from before a reset or reconnect, does not exist
here. `SELECT * FROM macavity_status()` shows this session's events.

---

### My test's fault fired in the wrong connection, or not at all

Events are session-local. Arming on one connection has no effect on
another, including another connection from the same pool. Arm on the
connection that runs the code under test.

---

### Other sessions were disconnected

A `crash` event fired somewhere on the cluster. Look for
`macavity: crashing backend (PID …)` in the server log. See
[`crash`](actions.md#crash).

---

### Can I read the counters after a `crash`?

No. The registry lived in the backend that died, and the reconnected
session starts empty. The count-before-action guarantee is the same code
path as for `error`, so verify ordering with `error` and use `crash` for
recovery behaviour.

---

## Still Stuck?

- **Issues**: [GitHub Issues](https://github.com/crystallinecore/macavity/issues)
- **Email**: sivaprasad.off@gmail.com
