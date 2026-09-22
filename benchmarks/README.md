# Benchmarks for the AWS Advanced Ruby Driver Wrapper

Micro-benchmarks measuring the wrapper's own overhead, using
[benchmark-ips](https://github.com/evanphx/benchmark-ips). Results are reported in
iterations per second (higher is better).

## Benchmark files

| File | Measures | Needs a database? |
| --- | --- | --- |
| `wrapper_overhead_benchmarks.rb` | The wrapper's own overhead versus the driver it wraps: each wrapped call (query, prepare, escape, ping, result iteration) paired with the identical raw call against the same fake driver | No |
| `connection_plugin_manager_benchmarks.rb` | Plugin manager pipeline overhead (connect, internal connect, execute) as the plugin count scales across 0, 1, 2, 5, and 10 plugins | No |
| `real_plugin_chain_benchmarks.rb` | Cost of the `execute` pipeline with each real plugin enabled individually, plus the default plugin combo and a no-plugin baseline | No |
| `service_benchmarks.rb` | Per-call cost of the collaborating services (connection, host, session-state, error handler) that back the plugins | No |
| `rds_utils_benchmarks.rb` | RDS endpoint classification and metadata extraction, cached and uncached | No |
| `connection_url_parser_benchmarks.rb` | Per-connection URL and libpq conninfo parsing, and host-list splitting | No |
| `sql_method_analyzer_benchmarks.rb` | The per-statement SQL inspection that runs on every executed statement (transaction open/close, autocommit) | No |
| `sql_parser_benchmarks.rb` | Column/table SQL analysis used by the encryption plugin: the PostgreSQL AST parser (pg_query) versus the MySQL regex parser | No |
| `storage_benchmarks.rb` | The caches behind topology and monitor lookups: expiration cache, sliding expiration cache, storage service | No |

## Running

Install the benchmark dependency, then run any file directly:

```bash
bundle install
bundle exec ruby benchmarks/wrapper_overhead_benchmarks.rb
# ...and likewise for any other file in benchmarks/
```

Each report prints an iterations-per-second figure, `compare!` prints the relative
speeds, and a summary table is printed at the end.

## Results output

Each run writes machine-readable results to `benchmarks/results/` (gitignored), one CSV per
benchmark (the plugin-manager benchmark writes one CSV per pipeline: `connect.csv`,
`internal_connect.csv`, `execute.csv`). Every row carries ops/second and an error percentage;
`wrapper_overhead.csv` additionally carries the raw ops/second and the overhead in nanoseconds
per call.

## End-to-end overhead against a real database

The benchmarks here use a fake driver, so they run anywhere and isolate the wrapper's own machinery -
which is the precise figure you want. For a whole-system sanity check against a real database, there
is a separate integration spec, `spec/integration/wrapper_perf_spec.rb` (see its header and
`docs/development-guide/Performance.md`). It is a coarse check, not a precise benchmark: the wrapper's
per-call cost is a few microseconds, which is below the noise floor of a real database round trip, so
its per-query numbers are not meaningful in isolation. Use these fake-target benchmarks for the
per-call overhead figure.

## Reading the results of `connection_plugin_manager_benchmarks.rb`

Read how a pipeline's ops/second falls as the plugin count rises, not the absolute numbers.
The absolute figures depend on the machine and are meaningless on their own; the shape of
the curve, and the gap between 0 and 10 plugins, is the cost the plugin chain adds.

The services behind the terminal default plugin are replaced with constant-cost stubs
(`support/benchmark_services.rb`), so no real connection is opened and the terminal call is
close to free. What remains as the count grows is the pipeline's own per-call cost. The
plugins are no-op pass-throughs (`support/benchmark_plugin.rb`) that only hand control to the
next plugin.

Comparing across wrappers: compare the **overhead per plugin** (the slope of the curve, in
time per call), not the raw ops/second. Absolute numbers differ by runtime and by what each
wrapper's benchmark stubs, so only the incremental per-plugin cost is comparable.
