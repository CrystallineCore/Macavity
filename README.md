# macavity

Deterministic, session-local fault injection for PostgreSQL.

> ## ⚠ DESTRUCTIVE — TEST CLUSTERS ONLY
>
> macavity exists to break PostgreSQL on purpose. The `crash` action
> terminates the calling backend with `SIGKILL`; PostgreSQL's postmaster
> responds to any unclean backend exit by **disconnecting every other
> session and running crash recovery**. Never install this on a cluster
> holding data you care about, and never on a production cluster.

## What it is

macavity lets a session *arm* a fault at a named execution point, run
normally, and then have that fault injected deterministically:

```sql
SELECT macavity_arm('executor_start', 'error', 3);
-- statement 1: normal
-- statement 2: normal
-- statement 3: ERROR: macavity: injected error at fault point "executor_start"
```

Faults are one-shot and counted per session. The name is a nod to T. S.
Eliot's mystery cat, who is reliably absent from the scene of the crime —
which is roughly how a fault behaves here: it does its damage and is no
longer armed by the time you look. The evidence, though, is still on the
record, which is the one place the analogy breaks down deliberately.

- fault state is **session-local**, and **at most one fault can be armed
  per session**
- `macavity_arm()` and `macavity_disarm()` both return an empty 1×1 result
- `macavity_status()` exposes the current state: `armed`, `point`, `action`,
  `occurrence`, `hits`, `remaining`
- `hits` counts matching fault-point hits; `remaining` (`occurrence - hits`)
  falls by one on every matching hit, and both are updated **before** the
  fault action runs, so the hit that fires the fault is always recorded
- `crash` terminates the current backend; PostgreSQL then disconnects other
  backends as crash containment — that is the server's behaviour, not
  macavity state crossing sessions (see [About `crash`](#about-crash))
- a newly established session starts with no armed fault

## Why it exists

Error paths are the least-tested part of most database code. Making
PostgreSQL fail *on cue* — at commit, mid-statement, or by killing the
backend outright — turns "what happens if this errors out?" into a
repeatable test:

- checking that an extension's own hooks, callbacks and cleanup paths
  survive an error raised from inside the executor or at commit time
- exercising crash and recovery behaviour with a real, unclean backend death
- verifying that application retry logic does the right thing when a commit
  fails or a connection disappears
- reproducing timing-dependent bugs by stretching a specific operation

This is **v0.1**: a deliberately small foundation — four fault points, three
actions, no shared state — chosen so the whole thing can be read in one
sitting and extended without redesign.

## Installation

Requires PostgreSQL 16 or later (server development headers: the
`postgresql-server-dev-*` package on Debian/Ubuntu, `postgresql*-devel` on
RHEL). Older majors are rejected at compile time rather than failing
obscurely partway through the build.

```sh
make
make install          # may need sudo
```

The distribution carries a PGXN `META.json` (release status `testing`), so
it can also be built and installed with `pgxn install macavity` once
published.

Then, in a database on a **test** cluster:

```sql
CREATE EXTENSION macavity;
```

No `shared_preload_libraries` entry is needed: macavity allocates no shared
memory and installs its hooks when the library is loaded on first use. If
you prefer to load it in every session, `session_preload_libraries =
'macavity'` also works.

## Example usage

```sql
CREATE EXTENSION macavity;

SELECT * FROM macavity_points();
     point      |                         description
----------------+--------------------------------------------------------------
 executor_start | before executor execution begins (ExecutorStart_hook)
 executor_end   | after executor execution completes (ExecutorEnd_hook)
 before_commit  | before transaction commit processing (XACT_EVENT_PRE_COMMIT)
 before_abort   | during transaction abort processing (XACT_EVENT_ABORT)

-- fail the very next statement
SELECT macavity_arm('executor_start', 'error');

SELECT 1;
ERROR:  macavity: injected error at fault point "executor_start"

-- the fault is spent, so armed is false -- but the hit that fired it was
-- counted before the error was raised, so the counters are still there
SELECT * FROM macavity_status();
 armed |     point      | action | occurrence | hits | remaining
-------+----------------+--------+------------+------+-----------
 f     | executor_start | error  |          1 |    1 |         0

-- macavity_disarm() clears it completely
SELECT macavity_disarm();
SELECT * FROM macavity_status();
 armed | point | action | occurrence | hits | remaining
-------+-------+--------+------------+------+-----------
 f     |       |        |            |      |
```

Delay the fifth matching event instead of failing it:

```sql
SELECT macavity_arm('executor_start', 'delay', 5);
```

Make a commit fail, to test retry logic:

```sql
BEGIN;
SELECT macavity_arm('before_commit', 'error');
INSERT INTO orders VALUES (...);
COMMIT;
ERROR:  macavity: injected error at fault point "before_commit"
-- the transaction rolled back; the INSERT is gone
```

Inspect and cancel an armed fault at any time:

```sql
SELECT * FROM macavity_status();
 armed |     point      | action | occurrence | hits | remaining
-------+----------------+--------+------------+------+-----------
 t     | executor_start | delay  |          5 |    2 |         3

SELECT macavity_disarm();
```

## SQL API

| Function | Returns | Notes |
| --- | --- | --- |
| `macavity_arm(point text, action text, occurrence integer DEFAULT 1)` | `void` — an empty 1×1 result | Arms a one-shot fault in the current session. **At most one fault can be armed per session**; arming while one is already armed is an error. Also errors on an unknown point or action, on `occurrence <= 0`, and on a NULL argument. Arming resets `hits` to 0 and replaces any previously fired fault. |
| `macavity_disarm()` | `void` — an empty 1×1 result | Clears this session's fault — armed or already fired — along with its counters. Safe when nothing is armed. |
| `macavity_status()` | exactly one row: `armed, point, action, occurrence, hits, remaining` | The current state of this session's fault. See below. |
| `macavity_points()` | set of `point, description` | Read straight out of the implemented-points table, so it can never advertise a point this build does not have. |

### `macavity_status()` and the counters

`macavity_status()` always returns exactly one row, in one of three states:

| State | `armed` | Other columns |
| --- | --- | --- |
| **armed** — waiting for its occurrence | `t` | the armed configuration, with `hits` counting matching hits so far |
| **fired** — the fault has gone off | `f` | the fault that fired, with its final counters (`remaining` is 0) |
| **clear** — nothing armed, nothing fired since the last disarm | `f` | all NULL |

A **fired** fault is distinguished from a **clear** one by `point` being
non-NULL. It is kept deliberately, so you can confirm after an injected
error that the hit was recorded; `macavity_arm()` overwrites it and
`macavity_disarm()` clears it.

Column by column:

- **`hits`** counts *matching fault-point hits*: events at the armed point,
  in this session, since the fault was armed. Events at other points, and in
  other sessions, do not count.
- **`remaining`** is `occurrence - hits`, falling by one on every matching
  hit and reaching 0 on the hit that fires the fault.
- Both are updated **before** the configured action runs, so the hit that
  fires the fault is always included.
- The counters are **not transactional**: an injected `error` aborts its
  transaction, but the recorded hit is not rolled back with it — which is
  precisely what makes the fired-state counters worth reading.

For `macavity_arm('executor_end', 'error', 3)`, the sequence is:

| Matching hit | `hits` | `remaining` | Action |
| --- | --- | --- | --- |
| — (just armed) | 0 | 3 | — |
| 1 | 1 | 2 | none |
| 2 | 2 | 1 | none |
| 3 | 3 | 0 | `ERROR` raised, *after* the counters reached 3 / 0 |

The same ordering applies to `crash` — the hit is counted before the
`SIGKILL` — but nothing can read the result back afterwards, because the
counters lived in the backend that has just died.

## Supported actions

| Action | Effect |
| --- | --- |
| `error` | Raises `ERROR` (`SQLSTATE P0001`) at the fault point. Normal PostgreSQL semantics follow: the statement fails and the transaction is aborted. |
| `crash` | **Destructive.** Sends `SIGKILL` to the current backend's own PID. The backend dies immediately and uncleanly. See the warning below. |
| `delay` | Sleeps for a fixed 1 second. The duration is not part of the v0.1 API; because `occurrence` is the third argument, a future version can add `duration` as a fourth without breaking existing calls. Outside of abort processing, `delay` sleeps on the process latch, so `statement_timeout` and query cancellation still work during it. |

### About `crash`

`crash` sends `SIGKILL` to `MyProcPid` — the backend that armed the fault
and reached the fault point — and nowhere else; macavity never signals the
postmaster or another backend directly.

**The crashed connection cannot restore itself.** Everything that lived in
its memory, including macavity's fault state, is gone. The client must
reconnect, and the new session starts with nothing armed — fault state is
backend-local, so there is nothing to inherit. Any statement in flight is
lost; anything already committed survives (crash recovery replays it from
WAL).

**What happens to other sessions is PostgreSQL's doing, not macavity's.** A
backend that exits uncleanly always causes the postmaster to terminate the
remaining backends and run crash recovery — this is PostgreSQL's crash
containment, protecting shared memory after an unclean exit, and not
something an extension can opt out of. Those other sessions never had a
fault armed; they are disconnected exactly as they would be for any other
unclean backend exit. Fault configuration stays strictly session-local
throughout — the *mechanism* touches only the backend that armed the fault,
but the *consequence* is a cluster-wide restart performed by PostgreSQL
itself. That is exactly why this is test-cluster-only tooling.

## Supported fault points

| Point | PostgreSQL API used | Fires |
| --- | --- | --- |
| `executor_start` | `ExecutorStart_hook` | After the executor is initialized, before any tuple is produced. |
| `executor_end` | `ExecutorEnd_hook` | After the executor has shut down for that statement. |
| `before_commit` | `RegisterXactCallback`, `XACT_EVENT_PRE_COMMIT` | Before the commit record is written, while an error can still safely abort the transaction. |
| `before_abort` | `RegisterXactCallback`, `XACT_EVENT_ABORT` | While the transaction is aborting. |

All four are available through PostgreSQL's supported extension hook/callback 
APIs; macavity patches nothing in PostgreSQL core and does not depend on 
undocumented backend internals.

## Testing

```sh
make install
make installcheck    # pg_regress: API, validation, counters, error/delay faults
```

The four suites are:

| Suite | Covers |
| --- | --- |
| `macavity_basic` | API surface, arm/disarm bookkeeping, the skip that stops the arming statement counting itself |
| `macavity_errors` | every validation path: unknown point, unknown action, `occurrence <= 0`, NULL arguments, arming twice, `error` at `before_abort` |
| `macavity_counters` | `hits`/`remaining` after every matching hit at `occurrence` 1, 2 and 3; that the counters advance before the action runs; that non-matching events and aborts do not move them; that the counters are not transactional; and the armed → fired → clear states of `macavity_status()` |
| `macavity_faults` | faults that actually fire, using `error` and `delay`, at each point — including `executor_end` at `occurrence` 1, which checks that the hit is recorded (`hits` 1, `remaining` 0) even though the action raised an `ERROR` |

Counter readings while a `before_commit` fault is armed are taken inside
`BEGIN ... ROLLBACK`, since an abort does not disturb the count. Keep that
pattern in mind when adding tests.

Two things can't go in `pg_regress` and ship as scripts instead. Point them
at a **throwaway** cluster where `CREATE EXTENSION macavity` has been run:

```sh
test/session_test.sh -h /tmp -p 5432 -d contrib_regression   # safe
test/crash_test.sh   -h /tmp -p 5432 -d contrib_regression   # CRASHES the cluster
```

- `session_test.sh` needs two concurrent connections, which a single
  `pg_regress` session cannot provide: it shows that session A's fault
  fires only in session A, that session B reports nothing armed, and that
  fault state does not outlive the session that armed it. It injects only
  `error`, so it is safe on any test cluster.
- `crash_test.sh` covers the `crash` action: that `hits` advances on the
  matching hits leading up to the crash, that the backend dies at the
  configured occurrence and not before, that the cluster comes back, that
  the reconnected session reports `armed = false` with no stale
  configuration, and that data committed before the crash survives
  recovery. `pg_regress` cannot survive a cluster-wide restart mid-run,
  which is why this is separate.

The crashing hit itself can't be read back — the counters lived in the
backend that died — so the ordering guarantee is instead verified through
the `error` action, which takes the identical code path in
`macavity_event()` before the action runs.

## License

MIT. See [LICENSE](LICENSE).

Copyright © 2026 Sivaprasad Murali.
