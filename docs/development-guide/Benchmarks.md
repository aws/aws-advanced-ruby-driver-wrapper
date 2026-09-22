# Performance and Overhead

Every database operation goes through the wrapper's plugin pipeline before reaching the underlying
`mysql2`/`pg` driver, which adds some cost. The short version: the wrapper adds a **small, fixed
amount of work per call** - on the order of a microsecond - and against a real query that cost is too
small to measure, dwarfed by the network round trip to the database.

> All numbers below are **indicative and machine-dependent**. Regenerate them on your own hardware
> before relying on them. See the [benchmarks README](../../benchmarks/README.md) to reproduce.

## Per-query overhead against a real database: negligible

Measured end to end with the **default plugins** in `wrapper_perf_spec.rb`, running each operation through the wrapper and
through the raw driver against the same cluster, from a host co-located with it (sub-millisecond
round trips).

The result: the wrapper's per-query overhead is **too small to distinguish from normal round-trip
variation** - on a real query you cannot tell the wrapper from the raw driver. This is expected: the
wrapper adds a fixed handful of microseconds (see below), while even a fast same-region query is
hundreds of microseconds to milliseconds, most of it network. The wrapper's share is a rounding
error, even against the fastest same-AZ query.

## Per-call fixed cost

To measure the fixed cost directly - without network noise - each wrapped call is run against an
in-memory fake driver (no database, no plugins) paired with the identical raw call, so the difference
is purely the wrapper's own machinery (the plugin pipeline, call-context handling, result wrapping).

| Operation | Overhead per call |
| --- | --- |
| `query` | ~0.9 µs |
| `prepare` | ~0.8 µs |
| `escape` | ~0.7 µs |
| `ping` | ~0.8 µs |
| a call routed through `method_missing` | ~2 µs |

Result iteration is charged **once per `each` call, not per row** - the wrapper routes the whole
iteration through a single pipeline call - so its overhead stays roughly flat (about 2 µs) whether the
result has one row or a thousand.

These figures are stable because there is no network involved. They are the fixed cost that, against
a real query, disappears into the round-trip noise as described above. Do not read the raw-vs-wrapped
*ratio* here as a real-world slowdown: against a near-zero fake target the ratio looks large, but the
meaningful figure is the microseconds added, and a microsecond is nothing next to any real query.

## Connecting

Establishing a connection with the default plugins is the one place the wrapper does measurably more than the raw
driver: on the initial connection it performs an extra round trip or two to verify the endpoint role. This is a
**one-time cost per connection**, not per query, and with a connection pool - as Active Record uses - it is paid at
pool-fill and amortized across every query on that connection. Its size scales with connection latency, so it is larger
from a distant client and small close to the cluster.

## Reproducing and going deeper

- `benchmarks/` holds the fake-target micro-benchmarks (per-call overhead, plugin-chain scaling, SQL
  inspection, endpoint classification, caches) - stable, no infrastructure required.
- `spec/integration/wrapper_perf_spec.rb` is the end-to-end real-database comparison; run it from a
  host co-located with the cluster (a laptop over the internet is latency-dominated and its absolute
  numbers are not representative).

See the [benchmarks README](../../benchmarks/README.md) for how to run everything.
