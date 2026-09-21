# Tribute to the Fault Injectors

## Acknowledging the Tools That Came First

macavity did not invent fault injection for databases. It is a small,
deliberately narrow tool, and it exists alongside far more powerful ones.
This page honours the tools that inspired it, and is honest about where
each of them is the better choice.

---

## PostgreSQL Injection Points

### What Injection Points Do Brilliantly

Since **PostgreSQL 17**, the server itself has a fault-injection framework.
Developers place named points directly in core code:

```c
INJECTION_POINT("checkpoint-before-old-wal-removal");
```

and tests attach callbacks to them at run time with
`InjectionPointAttach()`. The `injection_points` test module in the source
tree wraps that in SQL (`injection_points_attach(name, action)` with the
actions `error`, `notice` and `wait`, plus `injection_points_wakeup()` and
`injection_points_detach()`).

#### 1. **They Reach Anywhere**

An injection point can sit inside heap access, WAL, checkpoints, index
builds or any other core path. PostgreSQL 17's backend already contains
more than twenty of them. **macavity cannot do this.** It has four points,
all at executor and transaction boundaries, because those are the only
places a normal extension hook reaches.

#### 2. **Cross-Process Choreography**

A `wait` action parks a process at a point until another session calls
`injection_points_wakeup()`. That makes reproducing race conditions between
backends, or between a backend and the checkpointer, a matter of writing a
test. **macavity has no equivalent.** Its events are strictly
session-local, and `delay` is a fixed one-second sleep.

#### 3. **They Are Part of PostgreSQL's Own Test Suite**

Injection points are how PostgreSQL's developers test PostgreSQL. They
come with the source tree, the TAP framework and the project's review
process.

### Where macavity Fits Instead

Injection points are compiled in only when the server is built with
`--enable-injection-points` (or `-Dinjection_points=true` with Meson).
Distribution packages are normally built without it, so a stock
PostgreSQL from `apt` or `dnf` cannot use them.

macavity is an ordinary extension. It works against the **same packaged
PostgreSQL your application runs on**, needs no special build and no
restart, and gives SQL-level control with deterministic counting and a
status view. If your question is "does my application survive a failed
commit on real PostgreSQL 16?", macavity answers it. If your question is
"what happens if the checkpointer dies between these two lines?", use
injection points.

See the PostgreSQL documentation on [injection points](https://www.postgresql.org/docs/17/xfunc-c.html)
in the C-language functions chapter.

---

## Greenplum's `gp_inject_fault`

### A Long Tradition

Greenplum has long shipped a fault injector for its own testing. Named
fault points are compiled into the server, and the `gp_inject_fault()`
function arms them with a fault type (for example an error, a panic, a
sleep or a suspension). Its full form targets a specific segment and session
and takes start and end **occurrence** counts. The idea of "fire on the Nth
time this is reached", which is central to macavity, has a long history
there.

### Where It Reigns Supreme

`gp_inject_fault` works across a distributed cluster: it can target one
segment of many, suspend a process and resume it later, and cover code
paths deep inside the server. macavity is single-node and session-local by
design, with a much smaller surface.

---

## Proxies and Operating-System Tools

### Network Faults

Tools such as **Toxiproxy** sit between the application and PostgreSQL
and inject latency, bandwidth limits, resets and timeouts on the
connection. Linux's **`tc netem`** does the same at the kernel level.

**macavity does not touch the network.** A `crash` looks like a lost
connection to the client, but everything macavity does happens inside a
backend. For "what if the network drops mid-query?", use a proxy.

### Killing Processes

The oldest fault injector is `kill -9` on a backend PID, or
`pg_terminate_backend()` for a clean termination. They are simple and
always available.

What they lack is **timing**. Killing a backend "during commit" from
outside is a race you win sometimes. macavity's `crash` at `before_commit`
lands exactly at the commit, every time, on exactly the Nth commit.

---

## PL/pgSQL and Triggers

The simplest fault injector is a trigger that raises an exception:

```postgresql
CREATE FUNCTION fail() RETURNS trigger LANGUAGE plpgsql
AS $$ BEGIN RAISE EXCEPTION 'injected'; END $$;
CREATE TRIGGER fail_insert BEFORE INSERT ON orders
FOR EACH ROW EXECUTE FUNCTION fail();
```

It is transactional, visible to every session, and needs no extension. For
"make inserts into this table fail", it is often the right answer.

macavity adds what a trigger cannot do: failing a `COMMIT` itself, failing
a `SELECT`, crashing the backend, counting to N across any kind of
statement, and leaving the rest of the database untouched for other
sessions.

---

## Summary

| Need | Best tool |
| --- | --- |
| Faults deep inside PostgreSQL (WAL, buffers, checkpointer) | Injection points (PostgreSQL 17+, special build) |
| Coordinated races between processes | Injection points `wait` / `wakeup` |
| Distributed, per-segment faults | `gp_inject_fault` (Greenplum) |
| Network latency, resets, partitions | Toxiproxy, `tc netem` |
| "Make writes to this table fail" | A trigger |
| Failed commits, executor errors, delays and precisely timed crashes, on stock packaged PostgreSQL | **macavity** |

---

**Thank you** to the PostgreSQL developers who built injection points, to
the Greenplum developers who showed how far a fault injector can go, and to
everyone who has ever tested an error path instead of hoping.
