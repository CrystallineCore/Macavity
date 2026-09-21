# macavity Architecture

## Overview

macavity is a small PostgreSQL extension, about 1,500 lines of heavily
commented C, that injects faults at four points in PostgreSQL's execution.
It patches nothing in PostgreSQL core. Every point is built on a documented
extension hook or callback, and all state lives in plain backend memory.

This page first describes the **model** (events, the registry, what counts
as a hit, firing order), then the **implementation** that realises it.

## Core Design Principles

### 1. **Determinism**

The same statements in the same order always produce the same result. An
event fires on exactly its Nth matching hit, and several events meeting at
one hit always run in the same fixed order. Nothing depends on timing,
randomness or other sessions.

### 2. **Session Locality**

Each backend has its own event registry. There is no shared memory, no lock
and no IPC, so one session can neither see nor affect another's events. The
only cross-session effect is PostgreSQL's own crash containment after a
`crash`.

### 3. **Evidence Before Action**

A hit is counted, and the event marked `completed`, **before** its action
runs. An injected `ERROR` or a `SIGKILL` can never erase the record of the
hit that caused it.

### 4. **Honest Surface**

macavity claims only what it implements. `macavity_points()` reads straight
from the implemented-points table, and combinations that cannot work, such
as `error` at `before_abort` or `crash` on Windows, are refused up front
rather than failing later.

---

## Events

An **event** is one armed fault:

| Field | Meaning |
| --- | --- |
| `event_id` | Backend-local integer ID: 1, 2, 3, … in creation order |
| `point` | The [fault point](fault_points.md) it watches |
| `action` | `error`, `delay` or `crash` (see [Actions](actions.md)) |
| `occurrence` | Which matching hit fires it; `1` means the next one |
| `hits` | Matching hits counted since the event was last armed |
| `remaining` | `occurrence - hits` |
| `state` | `armed`, `completed` or `disarmed` |

### Event States

```text
                 macavity_arm(point, action, occurrence)
                                  │
                                  ▼
             ┌────────────────► armed ─────────────────┐
             │                    │                    │
  macavity_arm(event_id)          │ Nth matching hit   │ macavity_disarm()
             │                    ▼                    ▼
             ├─────────────── completed            disarmed
             │                                         │
             └─────────────────────────────────────────┘
                          macavity_arm(event_id)
```

| State | Meaning | Fires? |
| --- | --- | --- |
| `armed` | Waiting for its occurrence | yes |
| `completed` | Reached its occurrence and fired | no |
| `disarmed` | Cancelled by `macavity_disarm()` before it fired | no |

**Reinstating** with `macavity_arm(event_id)` takes a `completed` or
`disarmed` event back to `armed`. It keeps the ID, point, action and
occurrence, and resets the counters. On an already-`armed` event it changes
nothing and returns `false`.

---

## The Event Registry

- **The registry is the history.** Nothing is removed except by
  `macavity_reset()` or the end of the session. There is no separate log.
- **IDs are never reused** while the registry lives. They restart at 1 only
  after `macavity_reset()` or in a new session.
- **Any number of events** can be armed at once, each with independent
  counters and state.
- **Not transactional.** An injected `error` aborts its transaction, but the
  recorded hit is not rolled back with it. Likewise, an event created,
  disarmed or reinstated in a transaction that rolls back stays that way.

---

## Hits and Counting

A **hit** is one arrival at a fault point in this session. It is a
**matching** hit for every armed event at that point. On each matching hit,
in this exact order:

1. `hits` is incremented (so `remaining` falls by one)
2. the threshold is tested: is `hits` now equal to `occurrence`?
3. if so, the event is marked `completed`
4. only then does its action run

For `macavity_arm('executor_end', 'error', 3)`:

| Matching hit | `hits` | `remaining` | Action |
| --- | --- | --- | --- |
| (just armed) | 0 | 3 | none |
| 1 | 1 | 2 | none |
| 2 | 2 | 1 | none |
| 3 | 3 | 0 | `ERROR` raised after the counters reached 3 / 0; `state` is `completed` |

The same ordering applies to `crash`, but nothing can read the counters
back afterwards, because the registry lived in the backend that died.

### What Produces Executor Hits

`executor_start` and `executor_end` are reached once for every query that
goes through PostgreSQL's executor in this session:

| Statement | Executor hit? |
| --- | --- |
| `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `VALUES` | yes, one of each |
| macavity's own functions (`SELECT macavity_status()` …) | yes: they are ordinary `SELECT`s |
| `EXPLAIN` without `ANALYZE` | yes: the executor is started and ended to build the plan output |
| Queries inside functions: `PERFORM`, `SELECT … INTO`, SQL-function and trigger bodies | yes, each one, in addition to the outer statement |
| PL/pgSQL fast-path expressions such as `a := 1 + 1` | no |
| Utility statements: `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, DDL, `SET`, `DO`, `CALL` | no (statements *inside* a `DO` or `CALL` body can be) |

When in doubt, measure: arm a `delay` with a huge occurrence, run the code,
and read `hits`. The status query adds one `executor_start` hit (counted
before it reads) and one `executor_end` hit (counted after).

`before_commit` and `before_abort` are reached once per **top-level**
transaction end.

### The Arming Skip

The statement that arms (or reinstates) an event is already running when the
event becomes armed, and some of its fault points are still ahead of it.
Those are not counted:

`executor_end`
: The arming statement's own `ExecutorEnd` is skipped, so the first matching
  hit is the next statement's.

`before_commit` / `before_abort`
: In autocommit mode, the arming statement's implicit commit is skipped.
  Inside `BEGIN … COMMIT`, your own `COMMIT` (or the abort of that block) is
  a legitimate target and is counted.

`executor_start`
: Nothing to skip: the arming statement's `ExecutorStart` ran before the
  event existed.

Each skip applies at most once and never outlives the arming statement. If
the arming statement **fails** after arming, for example

```postgresql
SELECT macavity_arm('executor_end', 'error', 2), 1 / (random() * 0)::int;
```

its `ExecutorEnd` never runs and nothing is skipped. The event stays armed,
and the next two statements are hits 1 and 2. The same holds when the error
is caught by a PL/pgSQL exception block.

### Several Events at One Hit

When several armed events match one hit, they are visited in a fixed order:

1. by action: **`delay` > `crash` > `error`**
2. within one action, by ascending **`event_id`** (ID order, not the order
   of arming or reinstating)

Each event is counted and, if due, fired before the next is visited. `delay`
returns, so evaluation continues. `crash` and `error` do not, so the events
after them are **not reached** for that hit: they are neither counted nor
fired.

- `delay` + `error` both due: one-second pause, then the error
- `error` + `crash` both due: a crash; the error is never raised
- two `error`s both due: the lower ID fires; the higher ID is not counted
  and stays armed

---

## Implementation

### Source Layout

| Layer | File | Responsibility |
| --- | --- | --- |
| 1. SQL API | `src/macavity_api.c` | Argument validation and result formatting. All user-facing messages and SQLSTATEs live here. |
| 2. Event registry | `src/macavity_state.c` | What an event *is*: storage, states, counting, firing order, the arming skips |
| 3. Hook integration | `src/macavity.c` | The only file that knows PostgreSQL's hook APIs; holds all version-dependent signatures |
| 4. Actions | `src/macavity_action.c` | Carries out `error`, `delay` and `crash` |

`src/macavity.h` holds the shared types.

### Hooks

`_PG_init()` chains onto the previous value of every hook, so macavity
co-exists with other extensions that use them:

```text
ExecutorStart_hook ──► previous hook / standard_ExecutorStart ──► fire(executor_start)
ExecutorRun_hook   ──► nesting depth ++ ... -- (never a fault point)
ExecutorFinish_hook──► nesting depth ++ ... -- (never a fault point)
ExecutorEnd_hook   ──► previous hook / standard_ExecutorEnd   ──► fire(executor_end)
XactCallback
   XACT_EVENT_PRE_COMMIT ──► fire(before_commit)
   XACT_EVENT_ABORT      ──► fire(before_abort), clear per-transaction state
   XACT_EVENT_COMMIT     ──► clear per-transaction state
```

`PARALLEL_*` and `*PREPARE*` transaction events are deliberately ignored.
PostgreSQL 18 removed `execute_once` from `ExecutorRun`, and that
difference is isolated behind `PG_VERSION_NUM` in `macavity.c`. Nothing
allocates shared memory, so the library loads on demand.

### Registry Storage

Events live in one array in a dedicated memory context under
`TopMemoryContext`. IDs are dense, so event *N* is `events[N - 1]`: O(1)
lookup, and `macavity_reset()` is one `MemoryContextReset()`.

Each (point, action) pair has a **bucket** of event IDs, appended in
creation order and so already sorted by ID. Firing order at a point is
simply that point's buckets taken in precedence order (`delay`, `crash`,
`error`). Events never move between buckets, and state is checked during
the walk. A hit therefore touches only the events at **its own** point,
which is why events armed at other points cost nothing (see
[Performance & Overhead](performance.md)).

All creation-time allocation happens before anything is modified, so an
out-of-memory error leaves the registry exactly as it was.

### Firing

`macavity_fire(point)` walks the buckets with `macavity_event_next()`,
which for each armed, non-skipped event increments `hits`, tests the
threshold, marks the event `completed`, and hands its action back. The
caller runs the action and resumes the walk. An action that does not return
ends the walk.

### Skip Mechanics

`skip_exec_end_depth`
: For `executor_end` events: the executor nesting depth at which the arming
  statement's `ExecutorEnd` will run (the current depth minus one). The
  first `executor_end` hit at exactly that depth is skipped.

  If the arming statement fails instead, the `ExecutorRun` and
  `ExecutorFinish` hooks catch the error on its way out, restore the depth,
  call `macavity_exec_unwound(depth)` to drop every skip at that depth or
  deeper, and rethrow. That covers PL/pgSQL exception blocks, where no
  transaction abort happens. `macavity_xact_cleanup()` also clears any
  leftover skip at commit and abort as a backstop.

`skip_xact_event`
: For `before_commit`/`before_abort` events armed outside a transaction
  block (`!IsTransactionBlock()`): the next transaction end belongs to the
  arming statement and is skipped. Cleared at every transaction end.

### Actions

- **`error`**: `ereport(ERROR)` with `ERRCODE_RAISE_EXCEPTION`.
- **`delay`**: `WaitLatch()` loop with `CHECK_FOR_INTERRUPTS()`, so
  cancellation works. At `before_abort`, an uninterruptible `pg_usleep()`.
- **`crash`**: a `LOG` line, then `kill(MyProcPid, SIGKILL)`, then `PANIC`
  if it somehow returns. Compiled out on Windows.

### Invariants Worth Preserving

- The hit is counted before the action runs.
- The event is marked `completed` before the action runs.
- Firing order is fixed: action precedence, then ascending ID.
- No per-transaction or per-statement skip state survives its statement or
  transaction.
- `macavity_points()` reads from the implemented-points table and nothing
  else.
