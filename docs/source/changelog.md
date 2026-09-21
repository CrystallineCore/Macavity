# Changelog

## Unreleased

### Fixed

- **`executor_end` fired one statement late when the arming statement
  failed.** If the statement that armed (or reinstated) an `executor_end`
  event raised an error after arming, the one-shot skip reserved for that
  statement's own `ExecutorEnd` was never consumed. It then swallowed the
  next legitimate hit. With `occurrence 2`, the event fired at the third
  statement instead of the second. This happened at top level, inside a
  rolled-back transaction block, and when the error was caught by a PL/pgSQL
  exception block. The skip is now dropped when an error unwinds out of the
  arming statement's executor, and cleared at every transaction end as a
  backstop. Reproduced and verified on PostgreSQL 16, 17 and 18.

### Changed

- `macavity_points()` now describes `before_abort` as "during top-level
  transaction abort, not subtransaction rollback".
- On Windows builds, `macavity_arm()` refuses the `crash` action with
  `feature_not_supported`, instead of arming an event whose `SIGKILL` could
  not be delivered.

### Documentation

- Corrected the README walkthrough: after `macavity_arm(1)` re-arms an
  `executor_start` error event, the next statement receives the error. The
  example previously showed `macavity_reset()` succeeding there.
- Documented that `before_abort` fires only on top-level aborts, not on
  `ROLLBACK TO SAVEPOINT` or caught PL/pgSQL exceptions.
- Documented the arming skip, tested PostgreSQL versions (16, 17, 18) and
  platform support.
- Added this Read the Docs site, with the Testing Patterns, Performance &
  Overhead, Tribute and FAQ pages.

## 0.2.0

- The single armed fault became a backend-local **event registry**. Any
  number of events can be armed at once, each with a stable integer ID,
  independent counters and an `armed` / `completed` / `disarmed` state.
- `macavity_arm(point, action, occurrence)` now returns the new event's ID.
- New `macavity_arm(event_id)` reinstates a completed or disarmed event with
  fresh counters.
- New shorthands `macavity_arm_error()`, `macavity_arm_delay()` and
  `macavity_arm_crash()`.
- `macavity_disarm()` takes an optional event ID and returns `boolean`.
- `macavity_status()` returns one row per event, in every state.
- `macavity_reset()` empties the registry and returns the number of events
  discarded.
- Defined a fixed firing order for several events meeting at one hit: `delay` >
  `crash` > `error`, then ascending `event_id`.
- Upgrade with `ALTER EXTENSION macavity UPDATE`, then re-issue `GRANT`s on
  the recreated functions.

## 0.1.0

- Initial release: one armed fault per session at four fault points
  (`executor_start`, `executor_end`, `before_commit`, `before_abort`), with
  three actions (`error`, `crash`, `delay`).
