# Verifying macavity

How macavity tests itself. It ships three kinds of test; run all of them
against a **throwaway** cluster.

---

## Regression Suite (`pg_regress`)

```sh
make install
make installcheck
```

Use `PGHOST`, `PGPORT`, `PGUSER` and `PG_CONFIG` to pick the server.

| Suite | Covers |
| --- | --- |
| `macavity_basic` | API surface, ID-returning arm functions, disarm/reset bookkeeping, the skip that stops the arming statement counting itself |
| `macavity_errors` | Every validation path, for both the generic and the action-specific forms: unknown point, unknown action, `occurrence <= 0`, NULL arguments, `error` at `before_abort`, reinstating an unknown ID. Also that failed calls create nothing and consume no ID. |
| `macavity_counters` | `hits`/`remaining` after every matching hit at `occurrence` 1, 2 and 3; counters advance before the action runs; non-matching hits and aborts do not move them; reinstating resets them and disarming keeps them; they are not transactional |
| `macavity_faults` | Events that actually fire, using `error` and `delay`, at each point. Includes `executor_end` at `occurrence` 1 (the hit is recorded even though the action raised an `ERROR`), the autocommit skip on reinstatement, an arming statement that fails after arming `executor_end` (at top level, in a rolled-back block, and caught in PL/pgSQL), and `before_abort` not firing on `ROLLBACK TO SAVEPOINT` or a PL/pgSQL exception block. |
| `macavity_events` | The registry: monotonic IDs and their restart after reset; several events at the same and at different points; completion and retention; disarming one and all; reinstating completed, disarmed and already-armed events; precedence `delay` > `error`; equal actions in ID order; delay/error/abort interplay at `COMMIT` |

Counter readings while a `before_commit` fault is armed are taken inside
`BEGIN … ROLLBACK`, since an abort does not disturb the count. Keep that
pattern in mind when adding tests.

---

## Scripts That `pg_regress` Cannot Run

Point these at a cluster where `CREATE EXTENSION macavity` has been run:

```sh
test/session_test.sh -h /tmp -p 5432 -d contrib_regression   # safe
test/crash_test.sh   -h /tmp -p 5432 -d contrib_regression   # CRASHES the cluster
```

`session_test.sh`
: Needs concurrent connections, which a single `pg_regress` session cannot
  provide. It shows that session A's event fires only in session A; that
  session B starts with an empty registry; that two live sessions allocate
  IDs independently (both start at 1); that disarm and reset in one session
  leave the other's events armed; and that the registry does not outlive
  its session. It injects only `error`, so it is safe on any test cluster.

`crash_test.sh`
: Covers the `crash` action. It checks that `hits` advances on the hits
  leading up to the crash, that the backend dies at the configured
  occurrence and not before, that the cluster comes back, that the
  reconnected session has an empty registry with IDs starting at 1, that
  data committed before the crash survives recovery, and the two precedence
  rules involving `crash`: `crash` beats `error`, and `delay` runs before
  `crash`, each regardless of event IDs. It crashes the cluster three
  times.

The crashing hit itself cannot be read back, because the counters lived in
the backend that died. The count-before-action guarantee is therefore
verified through the `error` action, which takes the identical code path in
`macavity_event_next()`.

---

## Testing Against Several Majors

Build and test once per server, pointing at its `pg_config`:

```sh
for pgc in /usr/lib/postgresql/{16,17,18}/bin/pg_config; do
    make clean && make PG_CONFIG=$pgc && sudo make PG_CONFIG=$pgc install
    make PG_CONFIG=$pgc installcheck PGPORT=...   # that server's port
done
```

---

## Building These Docs

```bash
pip install -r docs/requirements.txt
make -C docs html SPHINXOPTS=-W
```

Open `docs/build/html/index.html`. `-W` makes warnings fatal, as on Read
the Docs.
