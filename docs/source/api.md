# API Reference

Complete reference for the macavity SQL API: extension management, arming
functions, event management, inspection, and every error message.

---

## Overview

| Function | Returns | Purpose |
| --- | --- | --- |
| [`macavity_arm(point, action, occurrence)`](#api-arm) | `integer` | Create a new armed event |
| [`macavity_arm_error / _delay / _crash`](#api-arm-action) | `integer` | Shorthands for one action |
| [`macavity_arm(event_id)`](#api-arm-event) | `boolean` | Reinstate an existing event |
| [`macavity_disarm(event_id)`](#api-disarm) | `boolean` | Disarm one event, or all |
| [`macavity_status()`](#api-status) | `setof record` | List every event and its counters |
| [`macavity_reset()`](#api-reset) | `integer` | Empty the registry |
| [`macavity_points()`](#api-points) | `setof record` | List the implemented fault points |

Calling any of these is itself a `SELECT`, and so an `executor_start` and
`executor_end` hit for events already armed at those points. See
[Architecture](architecture.md#what-produces-executor-hits).

---

## Extension Management

### CREATE EXTENSION

Creates the macavity functions in the current database.

**Syntax**:
```postgresql
CREATE EXTENSION macavity [ WITH ] [ SCHEMA schema_name ] [ VERSION version ];
```

**Parameters**:
- `schema_name`: schema to install into. The extension is relocatable.
- `version`: version to install (default: `0.2.0`)

**Example**:
```postgresql
CREATE EXTENSION macavity;
CREATE EXTENSION macavity SCHEMA testing;
```

**Notes**:
- Requires a superuser: the extension is not `trusted`.
- Revokes every function except `macavity_points()` from `PUBLIC`. See
  [Privileges](#privileges).

---

### ALTER EXTENSION … UPDATE

Upgrades an existing installation.

**Syntax**:
```postgresql
ALTER EXTENSION macavity UPDATE [ TO version ];
```

**Example**:
```postgresql
ALTER EXTENSION macavity UPDATE;          -- 0.1.0 -> 0.2.0
```

**Side Effects**:
- `macavity_arm(text, text, integer)`, `macavity_disarm()` and
  `macavity_status()` are dropped and recreated. Re-issue their `GRANT`s.
- Connected sessions keep the old library until they reconnect.

---

### DROP EXTENSION

**Syntax**:
```postgresql
DROP EXTENSION [ IF EXISTS ] macavity;
```

**Side Effects**:
- Sessions that already loaded the library keep its hooks until they
  disconnect. With nothing armed, the hooks cost nothing measurable.

---

## Arming Functions

(api-arm)=
### macavity_arm(point, action, occurrence)

Creates a new armed event in the current session and returns its ID.

**Syntax**:
```postgresql
macavity_arm(point text, action text, occurrence integer DEFAULT 1) RETURNS integer
```

**Parameters**:
- `point`: `executor_start`, `executor_end`, `before_commit` or
  `before_abort`. Case-sensitive. See [Fault Points](fault_points.md).
- `action`: `error`, `delay` or `crash`. Case-sensitive. See
  [Actions](actions.md).
- `occurrence`: which matching hit fires the event. `1` (the default) means
  the next one. Must be greater than zero.

**Returns**: the new `event_id` (1, 2, 3, … per session)

**Example**:
```postgresql
SELECT macavity_arm('executor_start', 'error');      -- next query fails
SELECT macavity_arm('executor_end', 'delay', 5);     -- 5th query ends 1 s late
SELECT macavity_arm('before_commit', 'crash', 10);   -- 10th commit crashes
```

**Errors**:

| Condition | SQLSTATE |
| --- | --- |
| Any argument is NULL | `22004` null_value_not_allowed |
| Unknown point | `22023` invalid_parameter_value |
| Unknown action | `22023` invalid_parameter_value |
| `occurrence <= 0` | `22023` invalid_parameter_value |
| `error` at `before_abort` | `0A000` feature_not_supported |
| `crash` on a Windows build | `0A000` feature_not_supported |
| Registry full (about 33 million events in one session) | `54000` program_limit_exceeded |

**Notes**:
- A call that fails creates nothing and consumes no ID.
- The arming statement is not counted as a hit where it would otherwise be
  one. See [The Arming Skip](architecture.md#the-arming-skip).

---

(api-arm-action)=
### macavity_arm_error / macavity_arm_delay / macavity_arm_crash

Shorthands for `macavity_arm(point, '<action>', occurrence)`.

**Syntax**:
```postgresql
macavity_arm_error(point text, occurrence integer DEFAULT 1) RETURNS integer
macavity_arm_delay(point text, occurrence integer DEFAULT 1) RETURNS integer
macavity_arm_crash(point text, occurrence integer DEFAULT 1) RETURNS integer
```

**Returns**: the new `event_id`

**Example**:
```postgresql
SELECT macavity_arm_delay('executor_start', 2),   -- 1
       macavity_arm_error('executor_start', 5),   -- 2
       macavity_arm_crash('before_commit', 10);   -- 3
```

**Errors**: as for `macavity_arm(point, action, occurrence)`

**Notes**:
- They exist so privileges can be granted per action. For example, a role
  can get `macavity_arm_error()` without being able to crash the server.

---

## Event Management

(api-arm-event)=
### macavity_arm(event_id)

Reinstates an existing event. A `completed` or `disarmed` event goes back to
`armed` with its original ID, point, action and occurrence, and fresh
counters.

**Syntax**:
```postgresql
macavity_arm(event_id integer) RETURNS boolean
```

**Returns**:
- `true`: the event was reinstated (`hits = 0`, `remaining = occurrence`)
- `false`: it was already `armed`, and was left untouched, counters included

**Example**:
```postgresql
SELECT macavity_arm(1);
```

**Errors**:

| Condition | SQLSTATE |
| --- | --- |
| `event_id` is NULL | `22004` null_value_not_allowed |
| No such event in this session | `42704` undefined_object |

**Notes**:
- A single argument always means this form, because creating an event needs
  at least a point and an action.
- The arming skip applies to a reinstatement exactly as to a new event.

---

(api-disarm)=
### macavity_disarm

Disarms one event, or every armed event.

**Syntax**:
```postgresql
macavity_disarm(event_id integer DEFAULT NULL) RETURNS boolean
```

**Parameters**:
- `event_id`: the event to disarm. NULL or omitted means every armed event.

**Returns**: `true` if at least one event went from `armed` to `disarmed`

**Example**:
```postgresql
SELECT macavity_disarm(3);   -- just event 3
SELECT macavity_disarm();    -- every armed event
```

**Errors**: none. An unknown ID just returns `false`.

**Notes**:
- `completed` and already-`disarmed` events are not changed.
- Disarmed events keep their counters and can be reinstated.

---

(api-reset)=
### macavity_reset

Discards the whole registry and restarts event IDs at 1.

**Syntax**:
```postgresql
macavity_reset() RETURNS integer
```

**Returns**: the number of events discarded

**Example**:
```postgresql
SELECT macavity_reset();
```

**Notes**:
- Afterwards the session behaves as though no event had ever been created.
- If an armed `executor_start` event is due, the reset statement itself may
  be the hit that fires it, and the reset does not run. Run it again, or
  disconnect.

---

## Inspection

(api-status)=
### macavity_status

Every event in this session's registry, in every state, ordered by
`event_id`.

**Syntax**:
```postgresql
macavity_status(
    OUT event_id integer, OUT point text, OUT action text,
    OUT occurrence integer, OUT hits integer, OUT remaining integer,
    OUT state text)
  RETURNS SETOF record
```

**Columns**:

| Column | Meaning |
| --- | --- |
| `event_id` | Backend-local ID |
| `point` | The event's fault point |
| `action` | `error`, `delay` or `crash` |
| `occurrence` | The matching hit that fires the event |
| `hits` | Matching hits since the event was last armed, counted before the action runs |
| `remaining` | `occurrence - hits`; 0 on the hit that fires the event |
| `state` | `armed`, `completed` or `disarmed` |

**Example**:
```text
=# SELECT * FROM macavity_status();
 event_id |     point      | action | occurrence | hits | remaining | state
----------+----------------+--------+------------+------+-----------+-------
        1 | executor_start | delay  |          2 |    1 |         1 | armed
        2 | executor_start | error  |          5 |    1 |         4 | armed
        3 | before_commit  | crash  |         10 |    0 |        10 | armed
```

**Notes**:
- An empty registry returns no rows.
- The status query is itself an `executor_start` hit, counted *before* it
  reads the registry, so the `hits` shown for an armed `executor_start`
  event already include this query.
- For `completed` events the counters are the final ones of the run that
  fired. For `disarmed` events they show how far it got.

---

(api-points)=
### macavity_points

The fault points this build implements.

**Syntax**:
```postgresql
macavity_points(OUT point text, OUT description text) RETURNS SETOF record
```

**Example**:
```postgresql
SELECT * FROM macavity_points();
```

**Notes**:
- Read straight from the implemented-points table, so it can never
  advertise a point the build lacks.
- The only function executable by `PUBLIC`.

---

## Privileges

`CREATE EXTENSION` runs:

```postgresql
REVOKE ALL ON FUNCTION macavity_arm(text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm(integer)             FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm_error(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm_delay(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_arm_crash(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_disarm(integer)          FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_status()                 FROM PUBLIC;
REVOKE ALL ON FUNCTION macavity_reset()                  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION macavity_points()              TO PUBLIC;
```

Grant explicitly. See [Installation: Grant Access](installation.md#grant-access).

---

## Error Reference

Every message macavity raises. All start with `macavity:`.

### Injected by an event

| Message | SQLSTATE | Cause |
| --- | --- | --- |
| `macavity: injected error at fault point "<point>"` | `P0001` | An `error` event fired. This is the fault you asked for. |
| `canceling statement due to statement timeout` | `57014` | Not macavity's own message: a `delay` outlasted `statement_timeout`. The event is still `completed`. |

### Raised by the arming functions

| Message | SQLSTATE | Cause and fix |
| --- | --- | --- |
| `macavity: point, action and occurrence must not be null` | `22004` | NULL passed to `macavity_arm(point, action, occurrence)` |
| `macavity: point and occurrence must not be null` | `22004` | NULL passed to a `macavity_arm_<action>()` shorthand |
| `macavity: event_id must not be null` | `22004` | NULL passed to `macavity_arm(event_id)` |
| `macavity: unrecognized fault point "<name>"` | `22023` | Unknown point. Names are lowercase and case-sensitive; the hint lists them. |
| `macavity: unrecognized action "<name>"` | `22023` | Unknown action; the hint lists `error, crash, delay` |
| `macavity: occurrence must be greater than zero, got <n>` | `22023` | `occurrence` was 0 or negative |
| `macavity: action "error" is not supported at fault point "before_abort"` | `0A000` | The abort is already under way there; an error would escalate to `FATAL`. Use `delay`/`crash`, or `error` at `before_commit`. |
| `macavity: action "crash" is not supported on Windows` | `0A000` | `crash` needs POSIX `SIGKILL` |
| `macavity: event <n> does not exist in this session` | `42704` | IDs are per session and restart after `macavity_reset()` |
| `macavity: event registry is full (<n> events)` | `54000` | Call `macavity_reset()` |

### Server log only

| Message | Level | Meaning |
| --- | --- | --- |
| `macavity: crashing backend (PID <pid>) at fault point "<point>"` | `LOG` | A `crash` event fired; written just before the `SIGKILL` |
| `macavity: suppressing injected error at fault point "before_abort"` | `WARNING` | Defensive only; `macavity_arm()` prevents this combination |
| `macavity: injecting 1000 ms delay at fault point "<point>"` | `DEBUG1` | A `delay` event fired |
