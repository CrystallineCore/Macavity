# Changelog

All notable changes to Macavity are documented in this file.

## 0.2.0

This release replaces the single armed fault with a **per-session event registry**. A session can now arm multiple fault events at once. Each event has a stable ID, independent counters, a lifecycle state, and can be re-armed after firing.

> **Breaking changes.** The return types and behavior of `macavity_arm()`, `macavity_disarm()` and `macavity_status()` have changed. See [Upgrading from 0.1.0](#upgrading-from-010).

### Added

* **Event registry.** Events are kept in a backend-local registry until `macavity_reset()` is called or the session ends. The registry also serves as the session's event history. Event IDs are allocated as 1, 2, 3, … in creation order and are never reused until reset.
* **Multiple armed events.** Any number of events can be armed simultaneously, at the same or different fault points. Each event maintains its own counters.
* **Event states.** Each event is `armed`, `completed` (it fired), or `disarmed` (it was cancelled before firing).
* **Deterministic firing order.** When multiple armed events match the same hit, they are evaluated by action in the order `delay` > `crash` > `error`, then by ascending `event_id`. A `delay` returns and evaluation continues; an `error` or `crash` ends evaluation, so later events are neither counted nor fired.
* `macavity_arm(event_id integer) RETURNS boolean` re-arms a `completed` or `disarmed` event. The event keeps its ID, point, action and occurrence, while its counters are reset. It returns `false` if the event is already armed. An unknown or NULL ID is an error.
* Action-specific shorthands: `macavity_arm_error(point, occurrence)`, `macavity_arm_delay(point, occurrence)` and `macavity_arm_crash(point, occurrence)`. Each returns the new event's ID.
* `macavity_reset() RETURNS integer` clears the registry, restarts event IDs at 1, and returns the number of discarded events.
* Added the `macavity_events` regression suite covering event IDs, concurrent events, state transitions, status output and firing precedence.
* Extended session and crash tests to cover multiple concurrent sessions and firing precedence under real crashes.
* Added `sql/macavity--0.1.0--0.2.0.sql` for `ALTER EXTENSION macavity UPDATE`.


### Changed

* **Breaking:** `macavity_arm(point, action, occurrence)` now returns the new event's `integer` ID instead of `void`.
* **Breaking:** `macavity_disarm(event_id integer DEFAULT NULL) RETURNS boolean` now:

  * disarms the specified event when given an ID;
  * disarms all armed events when called with no argument or NULL;
  * returns `true` if at least one event changed state;
  * preserves disarmed and completed events in the registry. Use `macavity_reset()` to clear them.
* **Breaking:** `macavity_status()` now returns one row per event (`SETOF record`) with the columns `event_id`, `point`, `action`, `occurrence`, `hits`, `remaining` and `state`.

  * The `state` column replaces the boolean `armed` column.
  * A session with no events now returns no rows.
* Arming a new event while another is armed is no longer an error.
* The arming-statement skip now applies to each event separately. The statement that arms or re-arms an event does not count toward that event's own `executor_end`, `before_commit` or `before_abort` hits.
* On Windows builds, `macavity_arm()` and `macavity_arm_crash()` reject the `crash` action with `feature_not_supported`.
* `macavity_points()` remains granted to `PUBLIC`. All new functions are revoked from `PUBLIC`, like the existing arming functions.
* Restructured the README with new "Overview", "Usage", "SQL API" and "How events behave" sections.

### Fixed

* Fixed an `executor_end` event firing one statement late when the statement that armed it failed. The per-statement skip is now discarded when execution unwinds due to an error, with a transaction-end backstop.

### Upgrading from 0.1.0

1. Build and install the new version:
   `make && make install`
2. Run `ALTER EXTENSION macavity UPDATE;` in each database that has the extension. The upgrade drops and recreates `macavity_arm()`, `macavity_disarm()` and `macavity_status()` because their return types changed.
3. **Re-issue any `GRANT`s** you had on those functions. The upgrade revokes the new and recreated functions from `PUBLIC`.
4. Update callers:

   * Replace checks on `armed` with checks on `state`, for example `WHERE state = 'armed'`.
   * Where you relied on `macavity_disarm()` to clear fired state, use `macavity_reset()` instead.
   * Code that expected one row from `macavity_status()` must now handle zero or multiple rows.
5. Existing sessions keep the old library loaded until they reconnect. No fault state is carried across the upgrade because fault state has always lived in backend memory.

## 0.1.0

Initial release.

* Session-local, one-shot fault injection, with at most one armed fault per session.
* Four fault points: `executor_start`, `executor_end`, `before_commit` and `before_abort`.
* Three actions: `error`, `delay` (fixed at 1 second) and `crash` (the backend sends `SIGKILL` to itself).
* `macavity_arm()`, `macavity_disarm()`, `macavity_status()` and `macavity_points()`. The `hits` and `remaining` counters are updated before the action runs.
* The `pg_regress` suites `macavity_basic`, `macavity_errors`, `macavity_counters` and `macavity_faults`, plus `test/session_test.sh` and `test/crash_test.sh`.

