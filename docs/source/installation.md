# Installation Guide

How to build, install and enable macavity on a **test** cluster.

---

## Requirements

- PostgreSQL **16 or later**, with its server development headers:
  - Debian/Ubuntu: `postgresql-server-dev-<major>`
  - RHEL/Fedora: `postgresql<major>-devel`
- A C compiler and `make` (the build uses PGXS)
- `pg_config` for the target server on your `PATH`, or passed as `PG_CONFIG=…`

Majors older than 16 are rejected at compile time with
`macavity requires PostgreSQL 16 or later`, rather than failing obscurely
partway through the build.

---

## Tested Versions and Platforms

| | Status |
| --- | --- |
| PostgreSQL 16, 17, 18 | **Tested.** The full `pg_regress` suite, `session_test.sh` and `crash_test.sh` pass on each (most recently 16.15, 17.11 and 18.6). |
| PostgreSQL 19 and later | **Not tested.** "16 or later" is the compile-time minimum, not a promise about future majors. The executor hook signatures macavity uses have changed before (PostgreSQL 18 changed `ExecutorRun_hook`), so build and run the [test suites](testing.md) before relying on a newer major. |
| Linux (x86-64) | **Tested.** |
| macOS, FreeBSD and other Unix-likes | **Not tested.** macavity uses only PostgreSQL's extension APIs plus POSIX `kill()`/`SIGKILL`, so it is expected to work, but this has not been verified. |
| Windows | **Not supported.** `crash` relies on POSIX `SIGKILL`, which PostgreSQL's Windows signal emulation cannot deliver, so on Windows builds `macavity_arm()` refuses `crash` with `feature_not_supported`. Nothing else has been built or tested on Windows. |

---

## Build from Source

```bash
git clone https://github.com/crystallinecore/macavity.git
cd macavity
make
sudo make install
```

To build against a specific server when several are installed:

```bash
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
sudo make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config install
```

---

## Install from PGXN

The distribution carries a PGXN `META.json` (release status `testing`):

```bash
pgxn install macavity
```

---

## Enable the Extension

In a database on a **test** cluster, as a superuser:

```postgresql
CREATE EXTENSION macavity;
```

Verify:

```postgresql
SELECT * FROM macavity_points();
```

The extension is not `trusted`, so creating it needs a superuser or the
privileges `CREATE EXTENSION` normally requires for untrusted extensions.

### No preload needed

macavity allocates no shared memory and installs its hooks when the library
is loaded on first use, so **no `shared_preload_libraries` entry is
needed**. To have the hooks present from the very start of every session
instead:

```ini
# postgresql.conf
session_preload_libraries = 'macavity'
```

---

## Grant Access

Arming a fault is a privileged operation: any role that can call
`macavity_arm_crash()` can take the whole cluster through crash recovery.
`CREATE EXTENSION` therefore revokes every function except
`macavity_points()` from `PUBLIC`. Grant what a test role needs explicitly:

```postgresql
GRANT EXECUTE ON FUNCTION
    macavity_arm(integer),
    macavity_arm_error(text, integer),
    macavity_arm_delay(text, integer),
    macavity_disarm(integer),
    macavity_status(),
    macavity_reset()
TO app_tester;
```

This set deliberately leaves out `macavity_arm_crash(text, integer)` and the
generic `macavity_arm(text, text, integer)`, since either can create `crash`
events. Grant those only to roles you would trust to restart the cluster.

---

## Upgrading from 0.1

Install the new build, then in each database:

```postgresql
ALTER EXTENSION macavity UPDATE;
```

The update drops and recreates `macavity_arm(text, text, integer)`,
`macavity_disarm()` and `macavity_status()`, whose return types changed in
0.2. **Re-issue any `GRANT`s on them afterwards.** Sessions that were already
connected keep the old library until they reconnect. No state is carried
over, because fault state has only ever lived in backend memory.

---

## Uninstalling

```postgresql
DROP EXTENSION macavity;
```

Sessions that already loaded the library keep its hooks until they
disconnect. With no events armed, the hooks do nothing measurable (see
[Performance & Overhead](performance.md)).

---

## Troubleshooting Installation

**`fatal error: postgres.h: No such file or directory`**
: The server development headers are missing. Install
  `postgresql-server-dev-<major>` (Debian/Ubuntu) or
  `postgresql<major>-devel` (RHEL/Fedora).

**`macavity requires PostgreSQL 16 or later`**
: `pg_config` points at an older server. Pass the right one with
  `make PG_CONFIG=…`.

**`could not open extension control file`**
: `make install` went to a different server's directories. Re-run it with
  the target server's `PG_CONFIG`.

**`permission denied for function macavity_arm`**
: See [Grant Access](#grant-access).

---

**Next:** [Quick Start Tutorial](quickstart.md)
