# Benchmarks

The wrapper ships micro-benchmarks that measure its own overhead - the cost the wrapper adds on top
of the underlying `mysql2`/`pg` driver. They live in [`benchmarks/`](../../benchmarks) and are run
with `benchmark-ips`; see the [benchmarks README](../../benchmarks/README.md) for how to run them and
regenerate the data.

## Wrapper overhead

`wrapper_overhead_benchmarks.rb` pairs each wrapped call with the identical call made directly
against the same target, so the difference between the pair is the wrapper's own contribution. The
figure that matters is the **overhead added per call**:

| Operation | Overhead per call |
| --- | --- |
| `query` | ~0.9 µs |
| `prepare` | ~0.85 µs |
| `escape` | ~0.75 µs |
| `ping` | ~0.85 µs |

Result iteration is charged **once per `each` call, not per row**, because the wrapper routes the
whole iteration through a single pipeline call. The overhead is therefore roughly flat as the result
grows:

| Rows iterated | Overhead per iteration |
| --- | --- |
| 1 | ~1.9 µs |
| 100 | ~1.8 µs |
| 1,000 | ~2.4 µs |

### How to read these numbers

- **This is the wrapper's fixed per-call cost, not query throughput.** The benchmark runs against a
  fake in-memory driver with no plugins enabled, so it isolates the wrapper's own machinery (the
  plugin pipeline, call-context handling, and result wrapping). There is no database round trip in
  these numbers.
- **Put it in perspective against a real query.** The wrapper adds roughly a microsecond of fixed
  overhead per call. A database round trip is typically hundreds of microseconds to milliseconds, so
  this overhead is a fraction of a percent of a real query.
- **Do not read the absolute call rates as throughput**, and do not compare these numbers against a
  raw driver as a "how many times slower" ratio - the raw side has no database work either, so that
  ratio has no bearing on real-world performance. Only the per-call overhead above is meaningful.
- **The numbers are indicative and machine-dependent.** They come from one run on one machine;
  regenerate them on your own reference hardware before treating any value as authoritative.

## Plugin pipeline overhead

`connection_plugin_manager_benchmarks.rb` measures how the plugin manager's per-call cost scales with
the number of plugins in the chain (0, 1, 2, 5, 10, and the default plugin set), across the
`connect`, `internal_connect`, and `execute` pipelines. The same "read the shape, not the absolute
numbers" guidance applies; see the [benchmarks README](../../benchmarks/README.md) for details.
