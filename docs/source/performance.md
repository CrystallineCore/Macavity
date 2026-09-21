# Performance & Overhead

What it costs to keep macavity loaded, and to have events armed.

---

## Summary

| Situation | Cost |
| --- | --- |
| Library not loaded | nothing: the hooks are not installed |
| Loaded, no events armed | **no measurable throughput change** in `pgbench`; about 20–40 ns per executor query in a tight loop |
| Events armed at *other* points | same as no events: a hit walks only its own point's events |
| *N* events armed at the point being hit | about **2.5 ns per armed event per hit** (100 events ≈ +0.25 µs per query) |
| An event firing | the action itself: an error, a 1-second sleep, or a crash |

macavity is test tooling, so these numbers mostly answer one question: *can
the library stay loaded on a test cluster while other tests run?* Yes.
Throughput is unaffected until you arm events, and even then the per-hit
cost is a few nanoseconds per event.

---

## Why It Is Cheap

- **No shared memory, no locks.** The registry is plain backend memory, so
  a hit never waits on another session.
- **Per-point buckets.** Events are filed by (point, action), so a hit at
  `executor_start` never looks at `before_commit` events.
- **Early exits.** With no events at a point, a hit is a walk over three
  empty buckets. The transaction-end cleanup is skipped entirely unless a
  skip flag was set in that transaction.
- **Nesting bookkeeping only.** The `ExecutorRun` and `ExecutorFinish`
  hooks just increment and decrement a counter around the real call.

See [Architecture](architecture.md#implementation) for details.

---

## Benchmark 1: Throughput (`pgbench -S`)

Select-only `pgbench` at scale 20, **1 client**, 10-second runs, 5 runs of
each configuration alternated to spread drift evenly. "Loaded" means
`session_preload_libraries = 'macavity'` for every pgbench connection, with
no events armed.

| Configuration | Runs (TPS) | Median TPS |
| --- | --- | --- |
| Not loaded | 16,083 · 14,775 · 16,217 · 16,147 · 15,480 | **16,083** |
| Loaded, no events | 16,068 · 15,166 · 15,990 · 15,836 · 16,310 | **15,990** |

The medians differ by 0.6%, well inside the run-to-run spread of about ±5%.
**No measurable difference.**

A run with 8 clients on the same 2-vCPU machine was dominated by CPU
contention: run-to-run spread was about ±10%, larger than any difference
between the configurations.

---

## Benchmark 2: Per-Query Hook Cost

A tighter measurement: one session runs **2,000,000** trivial executor
queries in a PL/pgSQL loop, so the hooks' cost is a larger share of the
total:

```postgresql
DO $$ BEGIN
  FOR i IN 1..2000000 LOOP
    PERFORM 1 FROM pg_class WHERE false;   -- one executor start/run/end per iteration
  END LOOP;
END $$;
```

Five runs per configuration, fresh session each run:

| Configuration | Median | Min – Max | Per query | vs. not loaded |
| --- | --- | --- | --- | --- |
| Not loaded | 1,799 ms | 1,778 – 1,842 | 0.90 µs | (baseline) |
| Loaded, no events | 1,871 ms | 1,825 – 1,959 | 0.94 µs | +36 ns |
| 1 event at `executor_start` | 1,836 ms | 1,807 – 1,867 | 0.92 µs | +18 ns |
| 100 events at `before_commit` (other point) | 1,951 ms | 1,812 – 2,265 | 0.98 µs | +76 ns, within noise |
| 100 events at `executor_start` (same point) | 2,301 ms | 2,263 – 2,325 | 1.15 µs | **+251 ns** |

Reading the table:

- **Loaded vs. not loaded**: about 20–40 ns per executor query. That is
  2–4% of the cheapest query PostgreSQL can run, and invisible in
  Benchmark 1.
- **Events at another point** cost the same as no events. The +76 ns median
  comes from one slow run (maximum 2,265 ms); the other four overlap the
  "loaded, no events" range.
- **Events at the point being hit** cost about **2.5 ns per event per hit**:
  +251 ns for 100 events. Every armed event at the point is counted on
  every hit, so cost is linear in the number of armed events there.
  Completed and disarmed events stay in their bucket and are skipped with a
  state check. That is cheaper than counting a live event, but not free, so
  thousands of dead events at a busy point add up. `macavity_reset()` clears
  them.

Events used an occurrence of 2,000,000,000 and the `delay` action, so none
fired during the measurement.

---

## Practical Guidance

**Fine to do:**
- Keep macavity loaded, or in `session_preload_libraries`, on a test cluster
- Arm a handful of events per test
- Arm events at `before_commit` in a session that also runs many queries

**Worth avoiding:**
- Accumulating thousands of completed events at `executor_start` or
  `executor_end` in a long-lived session that runs many queries. Call
  `macavity_reset()` between tests, or reconnect.
- Measuring the *performance* of code while events are armed at its
  executor points. Measure with the registry empty.

---

## Benchmark Environment

| | |
| --- | --- |
| CPU | Intel Xeon @ 2.10 GHz, 2 vCPU (cloud VM) |
| Memory | 7 GiB |
| OS | Linux 6.18 (Ubuntu 24.04 userland) |
| PostgreSQL | 16.15 (Ubuntu package), `shared_buffers = 128MB`, otherwise defaults |
| pgbench | 16.15, `-S -c 1 -j 1 -T 10`, scale 20 |
| macavity | 0.2.0 with the `executor_end` skip fix |
| Date | September 2026 |

These are small-VM numbers with visible noise. Treat them as orders of
magnitude, not as precise constants, and re-run the scripts on your own
hardware if the details matter.

### Reproducing

```bash
# Throughput: alternate configurations to spread drift
pgbench -i -s 20 bench
for r in 1 2 3 4 5; do
  PGOPTIONS=""                                        pgbench -S -c 1 -j 1 -T 10 -n bench
  PGOPTIONS="-c session_preload_libraries=macavity"   pgbench -S -c 1 -j 1 -T 10 -n bench
done
```

```postgresql
-- Per-query cost: in psql, with \timing on
SELECT count(macavity_arm('executor_start', 'delay', 2000000000))
  FROM generate_series(1, 100);            -- omit for the "no events" case
DO $$ BEGIN
  FOR i IN 1..2000000 LOOP PERFORM 1 FROM pg_class WHERE false; END LOOP;
END $$;
```
