# macavity

Deterministic, session-local fault injection for PostgreSQL.

> ## ⚠ DESTRUCTIVE — TEST CLUSTERS ONLY
>
> macavity exists to break PostgreSQL on purpose. The `crash` action
> terminates the calling backend with `SIGKILL`; PostgreSQL's postmaster
> responds to any unclean backend exit by **disconnecting every other
> session and running crash recovery**. Never install this on a cluster
> holding data you care about, and never on a production cluster.

## Overview

A session *arms* fault events at named execution points, runs normally, and
macavity injects the fault deterministically at the occurrence you chose: an
error, a delay, or an unclean backend crash. Events are one-shot, counted per
session, and reusable.

The name is a nod to T. S. Eliot's Macavity, the mystery cat who is reliably
absent from the scene of the crime, which is roughly how a fault behaves
here: it does its damage and is no longer armed by the time you look. The
evidence, though, is still on the record, which is the one place the analogy
breaks down deliberately.

Error paths are the least-tested part of most database code. Failing
PostgreSQL on cue makes questions like these repeatable tests: do an
extension's hooks and cleanup paths survive an error raised inside the
executor or at commit time; what does crash recovery do after a real,
unclean backend death; does application retry logic behave when a commit
fails or a connection disappears; can a timing-dependent bug be reproduced by
stretching one operation?

## Compatibility

| | Status |
| --- | --- |
| PostgreSQL 16, 17, 18 | Tested: the full `pg_regress` suite, `session_test.sh` and `crash_test.sh` pass on each (most recently 16.15, 17.11 and 18.6). |
| PostgreSQL 19 and later | **Not tested.** "16 or later" is the compile-time minimum, not a promise about future majors: the executor hook signatures macavity uses have changed before (PostgreSQL 18 changed `ExecutorRun_hook`). Build and run the test suites before relying on a newer major. |
| Linux (x86-64) | Tested. |
| macOS, FreeBSD, other Unix-likes | Not tested. macavity uses only PostgreSQL's extension APIs plus POSIX `kill()`/`SIGKILL`, so it is expected to work, but that is unverified. |
| Windows | **Not supported.** The `crash` action relies on POSIX `SIGKILL`, which PostgreSQL's Windows signal emulation cannot deliver, so on Windows builds `macavity_arm()` refuses `crash` with `feature_not_supported`. The rest has not been built or tested there. |

## Installation

Requires PostgreSQL 16 or later and its server development headers
(`postgresql-server-dev-*` on Debian/Ubuntu, `postgresql*-devel` on RHEL).
Older majors are rejected at compile time.

```sh
make
make install          # may need sudo
```

Then, in a database on a **test** cluster:

```sql
CREATE EXTENSION macavity;
```

No `shared_preload_libraries` entry is needed: macavity allocates no shared
memory and installs its hooks when the library is first used.
`session_preload_libraries = 'macavity'` also works.

The distribution carries a PGXN `META.json` (release status `testing`), so
`pgxn install macavity` will work once published.

**Upgrading from v0.1:** install the new build and run
`ALTER EXTENSION macavity UPDATE;`. This recreates `macavity_arm()`,
`macavity_disarm()` and `macavity_status()` (their return types changed), so
re-issue any `GRANT`s on them. Existing sessions keep the old library loaded
until they reconnect.

## Usage

```sql
-- fail the very next statement; the new event's ID comes back
SELECT macavity_arm('executor_start', 'error');
 macavity_arm
--------------
            1

SELECT 1;
ERROR:  macavity: injected error at fault point "executor_start"

-- the event is now completed, and its counters were recorded before the
-- error was raised
SELECT * FROM macavity_status();
 event_id |     point      | action | occurrence | hits | remaining |   state
----------+----------------+--------+------------+------+-----------+-----------
        1 | executor_start | error  |          1 |    1 |         0 | completed
```

While an `executor_start` or `executor_end` event is armed, every statement
counts as a hit, including `macavity_status()`, `macavity_disarm()` and
`macavity_reset()` themselves; to clean up while one is still due, run the
call again after it has taken the hit.

## SQL API

| Function | Returns | Description |
| --- | --- | --- |
| `macavity_arm(point text, action text, occurrence integer DEFAULT 1)` | `integer` | Creates an armed event and returns its `event_id`. `occurrence` is the matching hit that fires it (1 = the next one; must be > 0). Errors on an unknown point or action, a NULL argument, and `error` at `before_abort`. |
| `macavity_arm_error(point text, occurrence integer DEFAULT 1)`<br>`macavity_arm_delay(…)`<br>`macavity_arm_crash(…)` | `integer` | Shorthand for `macavity_arm(point, '<action>', occurrence)`, with the same validation. |
| `macavity_arm(event_id integer)` | `boolean` | Reinstates a `completed` or `disarmed` event with its counters reset. `false` if it was already `armed`; errors on an unknown or NULL ID. A single argument always means this form. |
| `macavity_disarm(event_id integer DEFAULT NULL)` | `boolean` | Disarms one event, or every armed event if the ID is omitted or NULL. `true` if at least one event changed state; an unknown ID returns `false`. Counters are kept. |
| `macavity_status()` | set of `event_id, point, action, occurrence, hits, remaining, state` | One row per event in the session's registry, in any state, ordered by `event_id`. No rows when the registry is empty. |
| `macavity_reset()` | `integer` | Empties the registry, restarts event IDs at 1, and returns the number of events discarded. |
| `macavity_points()` | set of `point, description` | Lists the fault points this build implements. |

All functions except `macavity_points()` are revoked from `PUBLIC`; grant
them explicitly to the roles that should be able to inject faults.

## How events behave

**Registry and IDs.** Each session keeps an in-memory event registry. It is
not persisted or shared with other sessions, and a new session (including one
opened after a crash) starts empty. Nothing leaves it except
`macavity_reset()`, so it is the session's event history. IDs are 1, 2, 3, …
in creation order across all arming functions, never reused, and restart at 1
only after a reset, so the same statements always produce the same IDs. Any
number of events can be armed at once, each with independent counters.

**States.** An event is `armed` (the only state that fires), `completed` (it
reached its occurrence and fired) or `disarmed` (cancelled by
`macavity_disarm()`). Reinstating with `macavity_arm(event_id)` returns a
completed or disarmed event to `armed` with the same ID, point, action and
occurrence and fresh counters; on an already armed event it changes nothing.

**Counters.** `hits` counts matching hits: at the event's point, in this
session, since the event was last armed. `remaining` is `occurrence - hits`.
Both are updated **before** the action runs, so the firing hit is always
recorded. For occurrence 3, `hits`/`remaining` go 0/3, 1/2, 2/1, 3/0 and the
`ERROR` follows on hit 3. Completed events keep their final counters;
disarmed events show how far they got.
Counters and registry are **not transactional**: an injected error aborts its
transaction but the recorded hit is not rolled back, and an event created,
disarmed or reinstated in a transaction that rolls back stays that way.
`crash` counts its hit the same way, but the registry dies with the backend,
so nothing can read it back.

**Firing order.** When several armed events match one fault point, each hit
visits them by action (**`delay` > `crash` > `error`**), then by ascending
`event_id` (not arming order). Each event is counted and, if due, fired
before the next is visited. A `delay` returns, so evaluation continues;
`error` and `crash` do not, so later events are **not reached** for that hit,
neither counted nor fired. A `delay` and an `error` due together give a
one-second pause and then the error; an `error` and a `crash` due together
give a crash and no error. The order is not configurable.

**The arming statement does not count itself.** The statement that arms or
reinstates an event is already running when the event becomes armed, so its
own upcoming fault points are skipped, once:

- `executor_end`: its own `ExecutorEnd` is skipped, so the first matching hit
  is the next statement's.
- `before_commit` / `before_abort`: in autocommit mode its implicit commit is
  skipped. Inside `BEGIN … COMMIT`, your own `COMMIT` (or the abort of that
  block) counts.
- `executor_start`: nothing to skip; the arming statement's `ExecutorStart`
  ran before the event existed.

The skip never outlives the arming statement. If that statement fails after
arming, e.g. `SELECT macavity_arm('executor_end', 'error', 2), 1 / (random() * 0)::int;`,
nothing is skipped: the event stays armed and the next two statements are
hits 1 and 2. The same holds if a PL/pgSQL exception block catches the
failure.

## Supported actions

| Action | Effect |
| --- | --- |
| `error` | Raises `ERROR` (`SQLSTATE P0001`) at the fault point. The statement fails and the transaction aborts as usual. |
| `crash` | **Destructive.** Sends `SIGKILL` to the current backend's own PID; it dies immediately and uncleanly. |
| `delay` | Sleeps a fixed 1 second (the duration is not part of the API yet; a future `duration` argument can follow `occurrence` without breaking existing calls). Outside abort processing it sleeps on the process latch, so `statement_timeout` and query cancellation still work. |

### About `crash`

`crash` signals only the backend that armed the event and reached the fault
point; macavity never signals the postmaster or another backend. That
connection cannot restore itself: everything in its memory, including the
registry, is gone, and the client must reconnect to a session with an empty
registry and IDs starting at 1. Any statement in flight is lost; anything
already committed survives, because recovery replays it from WAL.

What happens to other sessions is PostgreSQL's doing, not macavity's: any
unclean backend exit makes the postmaster terminate the remaining backends
and run crash recovery, and an extension cannot opt out. Those sessions never
had a fault armed. The mechanism touches only the arming backend; the
consequence is a cluster-wide restart, which is why this is test-cluster-only
tooling.

## Supported fault points

| Point | PostgreSQL API | Fires |
| --- | --- | --- |
| `executor_start` | `ExecutorStart_hook` | After the executor is initialized, before any tuple is produced. |
| `executor_end` | `ExecutorEnd_hook` | After the executor has shut down for that statement. |
| `before_commit` | `RegisterXactCallback`, `XACT_EVENT_PRE_COMMIT` | Before the commit record is written, while an error can still safely abort the transaction. |
| `before_abort` | `RegisterXactCallback`, `XACT_EVENT_ABORT` | While a **top-level** transaction is aborting: an error outside a savepoint, an explicit `ROLLBACK`, or a failed `COMMIT`. |

**`before_abort` does not fire on subtransaction rollback.** `ROLLBACK TO
SAVEPOINT`, a PL/pgSQL `BEGIN … EXCEPTION` block catching an error, and
anything else that rolls back only a subtransaction are not matching hits: a
`delay` armed there adds no time and `hits` does not move. PostgreSQL reports
those through `RegisterSubXactCallback` (`SUBXACT_EVENT_ABORT_SUB`), which
macavity does not hook. If the enclosing transaction later aborts as a whole,
that abort is a hit as usual.

All four use PostgreSQL's supported hook and callback APIs; macavity patches
nothing in core and does not depend on undocumented backend internals.

## Testing

```sh
make install
make installcheck 
```

| Suite | Covers |
| --- | --- |
| `macavity_basic` | API surface, ID-returning arm functions, disarm/reset bookkeeping, the arming-statement skip |
| `macavity_errors` | every validation path, and that failed calls create nothing and consume no ID |
| `macavity_counters` | `hits`/`remaining` at each matching hit; counters advance before the action; reinstate resets, disarm keeps; not transactional |
| `macavity_faults` | events that actually fire (`error`, `delay`) at each point; arming statements that fail after arming; `before_abort` and subtransactions |
| `macavity_events` | ID allocation, several events at once, every state transition, status output, firing precedence |

Two things can't run under `pg_regress` and ship as scripts. Point them at a
**throwaway** cluster where `CREATE EXTENSION macavity` has been run:

```sh
test/session_test.sh -h /tmp -p 5432 -d contrib_regression   # safe: injects only `error`
test/crash_test.sh   -h /tmp -p 5432 -d contrib_regression   # CRASHES the cluster
```

- `session_test.sh` uses concurrent connections to show that one session's
  events never fire in, appear in, or renumber another's, that disarm and
  reset in one session leave the other's events armed, and that the registry
  does not outlive its session.
- `crash_test.sh` covers `crash`: the backend dies at the configured
  occurrence and not before, the cluster recovers, the new session has an
  empty registry, committed data survives, and `crash` beats `error` while
  `delay` runs before `crash`, regardless of event IDs. It crashes the
  cluster three times, which `pg_regress` cannot survive.

## License

MIT. See [LICENSE](LICENSE).

Copyright © 2026 Sivaprasad Murali.
