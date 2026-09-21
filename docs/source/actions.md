# Actions

An action is what an event does when it fires. Action names are
case-sensitive and lowercase.

| Action | Effect | Returns? |
| --- | --- | --- |
| [`error`](#action-error) | Raises `ERROR` with SQLSTATE `P0001` | no |
| [`delay`](#action-delay) | Sleeps for 1 second | yes |
| [`crash`](#action-crash) | `SIGKILL`s the current backend | no |

Whether an action returns matters when
[several events meet at one hit](architecture.md#several-events-at-one-hit).

---

(action-error)=
## `error`

Raises:

```text
ERROR:  macavity: injected error at fault point "<point>"
```

with SQLSTATE **`P0001`** (`raise_exception`). Normal PostgreSQL semantics
follow: the statement fails and the transaction is aborted. Client code and
PL/pgSQL can catch it like any other error:

```postgresql
DO $$
BEGIN
    PERFORM 1;            -- reaches executor_start inside the block
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE 'caught: %', SQLERRM;
END $$;
```

`error` is not accepted at `before_abort`. See
{ref}`before_abort <before-abort>`.

---

(action-delay)=
## `delay`

Sleeps for a fixed **1 second** (`MACAVITY_DELAY_MS`), then lets execution
continue normally.

- Outside abort processing, the sleep waits on the process latch, so
  **`statement_timeout` and query cancellation still work** during it. A
  statement whose timeout is shorter than the delay is cancelled with
  `canceling statement due to statement timeout`.
- At `before_abort` the sleep is uninterruptible, because an error cannot be
  raised during abort processing.
- The duration is not configurable yet. Because `occurrence` is the last
  argument of every arming function, a future version can add a `duration`
  argument after it without breaking existing calls.

---

(action-crash)=
## `crash`

:::{danger}
`crash` terminates the calling backend **immediately and uncleanly**, and
PostgreSQL then restarts every other session on the cluster. Test clusters
only.
:::

`crash` writes one `LOG` line to the server log:

```text
LOG:  macavity: crashing backend (PID 12345) at fault point "before_commit"
DETAIL:  The backend is being terminated with SIGKILL by an armed macavity event.
HINT:  The postmaster will treat this as a backend crash and reinitialize the cluster.
```

and then sends `SIGKILL` to `MyProcPid`, the backend that armed the event
and reached the fault point, and to nothing else. macavity never signals
the postmaster or any other backend directly.

**The crashed connection cannot restore itself.** Everything that lived in
its memory, including macavity's event registry, is gone. The client must
reconnect, and the new session starts with an empty registry, with IDs
starting again at 1. Any statement in flight is lost. Anything already
committed survives, because crash recovery replays it from WAL.

**What happens to other sessions is PostgreSQL's doing, not macavity's.** A
backend that exits uncleanly always causes the postmaster to terminate the
remaining backends and run crash recovery. Other clients see
`terminating connection because of crash of another server process`. This
is PostgreSQL protecting shared memory after an unclean exit, and no
extension can opt out of it. Those sessions never had a fault armed. The
event registry stays strictly session-local throughout: the *mechanism*
touches only the backend that armed the event, but the *consequence* is a
cluster-wide restart performed by PostgreSQL itself.

`crash` is **POSIX-only**. On Windows builds, arming it fails with
`feature_not_supported`. See [Installation](installation.md#tested-versions-and-platforms).
