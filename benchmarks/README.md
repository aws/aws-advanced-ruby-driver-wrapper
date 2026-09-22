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

## Real-database overhead (co-located run)

The benchmarks above use a fake driver, so they run anywhere and isolate the wrapper's own
machinery. To measure end-to-end overhead against a real database instead, use the integration
spec `spec/integration/wrapper_perf_spec.rb`, which runs each operation through the wrapper (with
its default plugins) and through the raw driver against the same cluster, and reports the wrapper's
overhead as a percentage.

For that percentage to be representative, run it from a host **co-located with the cluster** - an EC2
instance in the same region (ideally same AZ as the writer) and VPC. A laptop over the internet is
latency-dominated (each connect is several round trips at tens to hundreds of milliseconds each),
which overstates the absolute times.

Steps:

1. Provision an EC2 instance in the cluster's VPC and region; prefer a non-burstable type (for
   example `m5`/`c5.large`) so CPU-credit throttling does not skew timings. Allow the DB port
   (5432 / 3306) from the instance's security group to the cluster.
2. Install Ruby (matching `.ruby-version`) and the driver build dependencies (`libpq-dev`,
   `default-libmysqlclient-dev` or the platform equivalents), clone the repo, and `bundle install`.
3. Set the connection env vars (`PG_HOST`/`PG_PORT`/`PG_USERNAME`/`PG_PASSWORD`/`PG_DATABASE`, and the
   `MYSQL_*` equivalents) to the cluster endpoint. Use a least-privilege, read-only database user -
   the spec only issues `SELECT 1`, a no-op transaction, `connect`, and `server_version` - and prefer
   a non-production cluster.
4. Warm up once, then record. The first connection to an endpoint pays a one-time dialect and
   topology discovery cost (then cached), and the results CSV appends across runs, so clear it
   between runs:

   ```bash
   rm -f spec/integration/results/wrapper_perf.csv
   bundle exec rspec spec/integration/wrapper_perf_spec.rb -e PostgreSQL   # warm-up (discard)
   rm -f spec/integration/results/wrapper_perf.csv
   bundle exec rspec spec/integration/wrapper_perf_spec.rb -e PostgreSQL   # recorded run
   ```

   Use `-e PostgreSQL` / `-e MySQL` to pick a context, or omit `-e` to run both when both databases
   are reachable.
5. Read the overhead percentages from the console output and from
   `spec/integration/results/wrapper_perf.csv`.

A quick way to confirm you are actually co-located: `time nc -zv $PG_HOST 5432` should report roughly
a millisecond, not tens or hundreds.

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
