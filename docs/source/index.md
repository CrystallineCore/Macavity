# macavity Documentation

Welcome to the official documentation for macavity.


```{toctree}
:maxdepth: 2
:caption: Contents:

installation
quickstart
api
architecture
fault_points
actions
patterns
performance
testing
tribute
faq
changelog
```


# macavity for PostgreSQL

**Deterministic, Session-Local Fault Injection for Testing**

---

:::{danger}
**Destructive: test clusters only.** The `crash` action terminates the
calling backend with `SIGKILL`, and PostgreSQL responds to any unclean
backend exit by **disconnecting every other session and running crash
recovery**. Never install macavity on a cluster holding data you care
about, and never on a production cluster.
:::

## What is macavity?

macavity is a PostgreSQL extension that makes PostgreSQL fail **on cue**. A
session *arms* fault events at named execution points, runs normally, and
has each fault injected on exactly the hit it asked for: an `ERROR` on the
third statement, a one-second stall at commit, or an unclean backend crash
on the tenth commit.

Error paths are the least-tested part of most database code. macavity turns
"what happens if this errors out?" into a repeatable test.

The name is a nod to T. S. Eliot's mystery cat, who is reliably absent from
the scene of the crime. A fault behaves much the same way here: it does its
damage and is no longer armed by the time you look. Unlike Macavity, though,
it leaves the evidence on record.

## Key Features

- **Deterministic**: an event fires on exactly the Nth matching hit, and
  several events meeting at one hit always run in the same documented order
- **Four Fault Points**: `executor_start`, `executor_end`, `before_commit`
  and `before_abort`, each built on a documented PostgreSQL hook
- **Three Actions**: `error`, `delay` (1 second) and `crash`
- **Session-Local**: every backend has its own in-memory event registry.
  No shared memory, no locks, no `shared_preload_libraries`
- **Observable**: `macavity_status()` shows every event's counters, and the
  hit that fires an event is recorded *before* its action runs
- **Reusable Events**: completed and disarmed events stay in the registry
  and can be reinstated by ID with fresh counters
- **Negligible Overhead**: no measurable throughput cost while loaded; see
  [Performance & Overhead](performance.md)

## What's New

### Fixed

* **`executor_end` no longer fires one statement late** when the statement
  that armed it fails. The skip reserved for the arming statement's own
  `ExecutorEnd` is now dropped when that statement dies, including when the
  error is caught by a PL/pgSQL exception block.

### Changed

* `macavity_points()` now describes `before_abort` as covering top-level
  aborts only, not subtransaction rollback.
* On Windows builds, `crash` is refused at arm time instead of arming an
  event whose `SIGKILL` could not be delivered.

See the [Changelog](changelog.md) for the full history.

## Quick Start

```postgresql
-- Install the extension (test cluster!)
CREATE EXTENSION macavity;

-- Fail the third statement from now
SELECT macavity_arm('executor_start', 'error', 3);

SELECT 'one';     -- runs
SELECT 'two';     -- runs
SELECT 'three';   -- ERROR:  macavity: injected error at fault point "executor_start"

-- The evidence survives the error
SELECT * FROM macavity_status();
```

## Documentation Structure

- **[Installation Guide](installation.md)**: build, install and grant access
- **[Quick Start Tutorial](quickstart.md)**: your first injected fault in 5 minutes
- **[API Reference](api.md)**: every function, parameter and error
- **[Architecture](architecture.md)**: events, counting, firing order and internals
- **[Fault Points](fault_points.md)**: where faults can be injected
- **[Actions](actions.md)**: what `error`, `delay` and `crash` do
- **[Testing Patterns](patterns.md)**: ready-made recipes for common tests
- **[Performance & Overhead](performance.md)**: what it costs to keep loaded
- **[Verifying macavity](testing.md)**: the extension's own test suites
- **[FAQ](faq.md)**: common questions and troubleshooting

## When to Use macavity

**Perfect For:**
- Testing application retry logic when a `COMMIT` fails
- Checking that an extension's hooks and cleanup survive an error
- Exercising crash and recovery with a real, unclean backend death
- Reproducing timeouts and lock waits on demand
- Finding the step of a migration that is not safely restartable

**Not Ideal For:**
- Production clusters, ever
- Faults deep inside PostgreSQL (WAL, buffers, locks): see
  [Tribute](tribute.md) for PostgreSQL's own injection points
- Network faults (use a proxy such as Toxiproxy)
- Faults in another session, or cluster-wide faults: events are
  session-local

## System Requirements

- PostgreSQL 16, 17 or 18 (tested); newer majors untested
- Linux (tested); other Unix-likes expected to work; Windows not supported
- No `shared_preload_libraries` entry, no shared memory

## License

macavity is open-source software released under the MIT License.

## Support

- **Issues**: [GitHub Issues](https://github.com/crystallinecore/macavity/issues)
- **Source**: [GitHub](https://github.com/crystallinecore/macavity)
- **Email**: sivaprasad.off@gmail.com

---

**Ready to break PostgreSQL on purpose?**

👉 [Start with the Installation Guide](installation.md)
