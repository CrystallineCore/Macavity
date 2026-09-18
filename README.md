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

Faults are one-shot, counted per session, and disarm themselves as soon as
they fire. The name is a nod to T. S. Eliot's mystery cat, who is reliably
absent from the scene of the crime — which is roughly how a fault behaves
here: it does its damage and is gone by the time you look at
`macavity_status()`.

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

Requires PostgreSQL 14 or later (server development headers: the
`postgresql-server-dev-*` package on Debian/Ubuntu, `postgresql*-devel` on
RHEL).

```sh
make
make install          # may need sudo
```

Then, in a database on a **test** cluster:

```sql
CREATE EXTENSION macavity;
```

No `shared_preload_libraries` entry is needed: macavity allocates no shared
memory and installs its hooks when the library is loaded on first use. If
you prefer to load it in every session, `session_preload_libraries =
'macavity'` also works.

`CREATE EXTENSION` requires superuser (the extension is not marked
`trusted`), and the arming functions are revoked from `PUBLIC` — only
superusers can arm a fault until you grant it explicitly:

```sql
GRANT EXECUTE ON FUNCTION macavity_arm(text, text, integer) TO test_harness;
GRANT EXECUTE ON FUNCTION macavity_disarm() TO test_harness;
GRANT EXECUTE ON FUNCTION macavity_status() TO test_harness;
```

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

-- the fault is spent; the session is back to normal
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
| `macavity_arm(point text, action text, occurrence integer DEFAULT 1)` | `void` | Arms a one-shot fault. Errors on an unknown point or action, on `occurrence <= 0`, on a NULL argument, and when a fault is already armed. |
| `macavity_disarm()` | `void` | Removes this session's fault. Safe when nothing is armed. |
| `macavity_status()` | one row: `armed, point, action, occurrence, hits, remaining` | When nothing is armed, `armed` is false and the rest are NULL. |
| `macavity_points()` | set of `point, description` | Read straight out of the implemented-points table, so it can never advertise a point this build does not have. |

## Supported actions

| Action | Effect |
| --- | --- |
| `error` | Raises `ERROR` (`SQLSTATE P0001`) at the fault point. Normal PostgreSQL semantics follow: the statement fails and the transaction is aborted. |
| `crash` | **Destructive.** Sends `SIGKILL` to the current backend's own PID. The backend dies immediately and uncleanly. See the warning below. |
| `delay` | Sleeps for a fixed 1 second. The duration is not part of the v0.1 API; because `occurrence` is the third argument, a future version can add `duration` as a fourth without breaking existing calls. |

Outside of abort processing, `delay` sleeps on the process latch, so
`statement_timeout` and query cancellation still work during the delay.

### About `crash`

The signal is sent to `MyProcPid` and to nothing else: macavity never
signals the postmaster, and never signals another backend. But a backend
that exits uncleanly always causes the postmaster to terminate the remaining
backends and run crash recovery — that is PostgreSQL's design, not something
an extension can opt out of, and simulating a crash without it would not be
simulating a crash. So:

- the *mechanism* touches only the armed backend
- the *consequence* is a cluster-wide restart and recovery

That is exactly why this is test-cluster-only tooling.

## Supported fault points

| Point | PostgreSQL API used | Fires |
| --- | --- | --- |
| `executor_start` | `ExecutorStart_hook` | After the executor is initialized, before any tuple is produced. |
| `executor_end` | `ExecutorEnd_hook` | After the executor has shut down for that statement. |
| `before_commit` | `RegisterXactCallback`, `XACT_EVENT_PRE_COMMIT` | Before the commit record is written, while an error can still safely abort the transaction. |
| `before_abort` | `RegisterXactCallback`, `XACT_EVENT_ABORT` | While the transaction is aborting. |

All four are ordinary, documented extension APIs. macavity patches nothing
in PostgreSQL core and reads no undocumented backend internals.

### Per-point limitations

**`executor_start`** — fires once per executor invocation, which includes
statements inside functions, `DO` blocks and SPI, not just top-level
statements. Injecting the fault *before* `standard_ExecutorStart()` would
leave a half-initialized `QueryDesc` behind for no extra test value, so the
fault is injected immediately after initialization instead.

**`executor_end`** — fires after the executor has been torn down, so an
`error` here fails the statement *after* its rows have already been sent to
the client. The client sees the error and the transaction still aborts, but
the result set was on the wire before the failure. Also note that the
statement calling `macavity_arm()` reaches its own `ExecutorEnd` after
arming; that one event is skipped, so `occurrence = 1` means "the next
statement", not "this one".

**`before_commit`** — `XACT_EVENT_PRE_COMMIT` is not reached by two-phase
commit (`PREPARE TRANSACTION` raises `XACT_EVENT_PRE_PREPARE` instead) and
is not reached by subtransaction release, so faults do not fire for `PREPARE
TRANSACTION` or for `RELEASE SAVEPOINT`. In autocommit mode the commit of
the arming statement itself is not counted — otherwise the fault would fire
before you could run anything. Inside an explicit `BEGIN ... COMMIT` block
your own `COMMIT` *is* counted, which is what makes the retry example above
work.

**`before_abort`** — **PostgreSQL has no pre-abort hook.** `XACT_EVENT_ABORT`
is called from `AbortTransaction()`, when the abort is already under way.
The consequences are worth stating plainly:

- `error` is **rejected at arm time** for this point. Raising an error
  during abort processing escalates to `FATAL` and disconnects the session,
  which is not what "inject an error" should mean. Use `before_commit` for
  that, or `crash`/`delay` here.
- `delay` at this point uses an uninterruptible sleep, because servicing
  interrupts mid-abort could throw.
- the name `before_abort` is kept because it names the *intent* ("when this
  transaction is going down"); "during abort processing" is what actually
  happens. Fixing that would require a core patch, which v0.1 explicitly
  does not do.

**Parallel workers** — hooks run in parallel workers too, but fault state is
backend-local and a worker does not inherit the leader's configuration, so a
fault armed in the leader never fires inside a worker. Parallel-specific
transaction events (`XACT_EVENT_PARALLEL_*`) are ignored.

## Session-local behaviour

Fault configuration is a plain backend-local static variable. There is no
shared memory, no lock, no IPC, and no background worker:

- session A arming a fault has no effect on session B
- multiple backends can arm different faults simultaneously without
  interfering
- the occurrence counter counts only events in the session that armed it
- state dies with the session — a disconnect is as good as a disarm

`test/session_test.sh` demonstrates all of this with two connections.

## Occurrence semantics

`occurrence` is *which matching event fires the fault*, counting only events
at the armed point, only in this session, and only after arming:

```sql
SELECT macavity_arm('executor_start', 'error', 3);
-- matching event 1 -> normal
-- matching event 2 -> normal
-- matching event 3 -> inject error, then disarm
```

- the default is `1`, meaning the next matching event
- `0` and negative values are rejected
- `macavity_status().hits` is how many matching events have been counted so
  far, and `remaining` is `occurrence - hits`
- the fault disarms itself the moment it fires, before the action runs, so
  behaviour is one-shot even for actions that never return
- events produced by the arming statement itself are not counted (see
  `executor_end` and `before_commit` above)

## Current limitations

- one armed fault per session; arming while a fault is armed is an error
  rather than a silent replacement
- one-shot only: no repeating, every-Nth or probability-based faults
- no filters by relation, schema, database or user
- fixed 1-second `delay`; no duration argument yet
- only the four points above — nothing at the WAL, heap, buffer or
  index level
- `before_abort` is really "during abort", and rejects `error` (above)
- `crash` cannot be covered by `pg_regress`; it has its own harness
- no background workers, no shared-memory configuration, and therefore no
  way to arm a fault in *another* session
- statements batched into one query message share a failure: if a fault
  fires partway through, the output of the earlier statements in that batch
  is lost with it

## Testing

```sh
make install
make installcheck    # pg_regress: API, validation, and error/delay faults
```

The three suites are `macavity_basic` (API surface and counter
bookkeeping), `macavity_errors` (every validation path), and
`macavity_faults` (faults that actually fire, using `error` and `delay`).

Two things cannot go in `pg_regress` and ship as scripts instead. Point them
at a **throwaway** cluster where `CREATE EXTENSION macavity` has been run:

```sh
test/session_test.sh -h /tmp -p 5432 -d contrib_regression   # safe
test/crash_test.sh   -h /tmp -p 5432 -d contrib_regression   # CRASHES the cluster
```

- `session_test.sh` needs two concurrent connections, which a single
  `pg_regress` session cannot provide. It injects only `error`, so it is
  safe on any test cluster.
- `crash_test.sh` covers the `crash` action: that the backend dies at the
  configured occurrence and not before, that the cluster comes back, and
  that data committed before the crash survives recovery. `pg_regress`
  cannot survive a cluster-wide restart mid-run, which is why this is
  separate.

## Architecture

Four layers, one file each, so a new point or action touches one of them
rather than all of them:

```
 SQL function                src/macavity_api.c      validation, result rows
     |
     v
 session-local fault state   src/macavity_state.c    point, action,
     |                                               occurrence, hits
     v
 PostgreSQL hook             src/macavity.c          the only file that
     |                                               knows about hook APIs
     v
 fault dispatcher            src/macavity_action.c   error / crash / delay
```

- `src/macavity_api.c` — every user-facing message and SQLSTATE. Layers below
  assume valid input.
- `src/macavity_state.c` — what a fault *is*, occurrence counting, and the
  skip rules that keep the arming statement from counting itself.
  `macavity_points()` reads its point table directly, so an unimplemented
  point cannot be advertised by accident.
- `src/macavity.c` — hook installation and chaining (previous hook values
  are saved and called), the executor nesting counter, and the transaction
  callback. All version-dependent signatures live here.
- `src/macavity_action.c` — the dispatcher. Adding an action means one `case`
  here plus one row in `macavity_action_info[]`.

Adding a fault point is: one enum value, one row in `macavity_point_info[]`,
and one `macavity_fire()` call from the relevant hook.

## PostgreSQL compatibility

Tested against PostgreSQL 16; the code targets 14 and later, and the
version-dependent pieces are isolated:

- `ExecutorRun_hook` lost its `execute_once` argument in PostgreSQL 18; the
  hook is compiled both ways behind `PG_VERSION_NUM` in `src/macavity.c`
  (`ExecutorStart_hook` itself still returns `void` in 18 and on master)
- the set-returning-function helper was renamed from `SetSingleFuncCall()`
  to `InitMaterializedSRF()` in PostgreSQL 15; both are handled in
  `src/macavity_api.c`

Everything else uses APIs that have been stable across all supported
branches.

## Future possibilities

Deliberately left out of v0.1, and none of them require the API to change
shape:

- a `duration` argument for `delay`, as a fourth parameter
- more points, as hooks allow: `ProcessUtility_hook`, planner and
  `ExecutorRun` entry, `ClientAuthentication_hook`, `object_access_hook`
- repeating faults (`every N events`) and a `times` argument, rather than
  strictly one-shot
- more actions: `warning`, `notice`, a `FATAL` disconnect that is not a
  crash, a `pg_terminate_backend`-style cancel
- filters by relation, database or user, for points where that is meaningful
- arming a fault in another session, which would need shared memory and a
  clear privilege model — and is the point at which this stops being a
  small extension

## License

PostgreSQL License.
