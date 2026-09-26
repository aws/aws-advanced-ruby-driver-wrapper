# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# End-to-end overhead of the wrapper (with its default plugins) against the raw driver, over a real
# database connection. Each workflow runs the identical operation on a wrapper connection and on a
# native driver connection and reports the wrapper's overhead as a percentage of the raw driver's
# time. Results are printed and written to spec/integration/results/wrapper_perf.csv.
#
# THIS IS A COARSE, ON-DEMAND SANITY CHECK, NOT A PRECISE PER-QUERY BENCHMARK. The wrapper's per-call
# cost is a few microseconds, which is *below the noise floor* of a real database round trip: across
# runs the per-query workflows swing between slightly negative (impossible in reality - the wrapper
# strictly does more work) and small positive, because run-to-run round-trip jitter is larger than
# the overhead being measured. Do not read a single run's per-query percentages as real overhead.
#
# What it is good for:
#   - Catching a *gross* regression (e.g. an accidental extra round trip per query would show a large,
#     consistent jump that survives the noise).
#   - The `connect` workflow, which measures a genuine one-time cost the fake-target benchmarks cannot:
#     the initial connection does an extra round trip or two for endpoint verification and topology
#     discovery. That cost is amortized by connection pooling.
#
# For the precise per-call overhead, use the fake-target micro-benchmark
# benchmarks/wrapper_overhead_benchmarks.rb - it has no network, so it is stable and reproducible.
#
# Run from a host co-located with the cluster; a laptop over the internet is latency-dominated and
# its absolute numbers are not representative.

require 'benchmark'
require 'csv'
require 'fileutils'

RESULTS_DIR = File.expand_path('results', __dir__)
RESULTS_PATH = File.join(RESULTS_DIR, 'wrapper_perf.csv')

# Times one batch of +batch+ calls and accumulates into +acc+. GC is settled and then disabled for
# the duration of the batch, so no collection lands inside the measured window (the wrapper allocates
# more per call, so an in-window collection otherwise inflated its total); it is re-enabled and the
# accumulated garbage reclaimed by the next batch's GC.start. Batches are small, so the garbage held
# while GC is off is negligible. Per-call times are captured for the distribution.
def run_batch(func, args, batch, acc)
  GC.start
  GC.disable
  acc[:total] += Benchmark.realtime do
    batch.times do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      func.call(*args)
      acc[:per_call] << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end
  end
ensure
  GC.enable
end

def stats(acc, count)
  sorted = acc[:per_call].sort
  {
    avg_ms: acc[:total] / count * 1000,
    median_ms: sorted[count / 2] * 1000,
    min_ms: sorted.first * 1000,
    max_ms: sorted.last * 1000
  }
end

def print_summary(workflow_name, driver_label, iterations, wrapper, vanilla, overhead_pct)
  puts "\n#{'=' * 60}"
  puts "#{driver_label} / #{workflow_name} (#{iterations} iterations)"
  puts '=' * 60
  puts "  wrapper avg #{wrapper[:avg_ms].round(4)} ms  " \
       "(median #{wrapper[:median_ms].round(4)}, min #{wrapper[:min_ms].round(4)}, max #{wrapper[:max_ms].round(4)})"
  puts "  raw     avg #{vanilla[:avg_ms].round(4)} ms  " \
       "(median #{vanilla[:median_ms].round(4)}, min #{vanilla[:min_ms].round(4)}, max #{vanilla[:max_ms].round(4)})"
  puts "  wrapper overhead: #{overhead_pct.round(1)}% vs raw driver"
  puts '=' * 60
end

def record_csv(workflow_name, driver_label, iterations, wrapper, vanilla, overhead_pct)
  FileUtils.mkdir_p(RESULTS_DIR)
  write_header = !File.exist?(RESULTS_PATH)
  CSV.open(RESULTS_PATH, 'a') do |csv|
    csv << %w[driver workflow iterations wrapper_avg_ms raw_avg_ms overhead_pct] if write_header
    csv << [driver_label, workflow_name, iterations,
            wrapper[:avg_ms].round(4), vanilla[:avg_ms].round(4), overhead_pct.round(1)]
  end
end

def gather_metrics(wrapper_func, wrapper_args, vanilla_func, vanilla_args, iterations, workflow_name, driver_label)
  # Discard a warm-up batch so JIT, connection state, and caches are hot before timing.
  warmup = [iterations / 5, 20].max
  warmup.times do
    wrapper_func.call(*wrapper_args)
    vanilla_func.call(*vanilla_args)
  end

  # Interleave wrapper and raw in small batches rather than one block each, so any latency drift over
  # the run affects both sides roughly equally. Each batch is timed as a total for GC amortization.
  rounds = [iterations / 50, 1].max
  batch = iterations / rounds
  measured = batch * rounds

  wrapper_acc = { total: 0.0, per_call: [] }
  vanilla_acc = { total: 0.0, per_call: [] }
  rounds.times do
    run_batch(wrapper_func, wrapper_args, batch, wrapper_acc)
    run_batch(vanilla_func, vanilla_args, batch, vanilla_acc)
  end

  wrapper = stats(wrapper_acc, measured)
  vanilla = stats(vanilla_acc, measured)
  overhead_pct = (wrapper[:avg_ms] - vanilla[:avg_ms]) / vanilla[:avg_ms] * 100

  print_summary(workflow_name, driver_label, measured, wrapper, vanilla, overhead_pct)
  record_csv(workflow_name, driver_label, measured, wrapper, vanilla, overhead_pct)

  expect(wrapper[:avg_ms]).to be > 0
  expect(vanilla[:avg_ms]).to be > 0
end

RSpec.shared_examples 'Plugin pipeline benchmarks' do |driver_helper|
  include driver_helper

  driver_label = driver_helper.to_s.delete_suffix('TestHelper').downcase

  it 'execute performance is comparable between wrapped and vanilla drivers' do
    @wrapper_conn = driver_helper.wrapper_connect
    @vanilla_conn = driver_helper.native_connect
    target_func = ->(conn) { driver_helper.execute(conn, 'SELECT 1') }
    gather_metrics(target_func, [@wrapper_conn], target_func, [@vanilla_conn], 1000, 'execute', driver_label)
  end

  # A short transaction exercises the per-statement transaction-state tracking that runs on every
  # executed statement, so it stresses the wrapper's always-on path more than a single SELECT.
  it 'transaction performance is comparable between wrapped and vanilla drivers' do
    @wrapper_conn = driver_helper.wrapper_connect
    @vanilla_conn = driver_helper.native_connect
    txn = lambda do |conn|
      driver_helper.execute(conn, 'BEGIN')
      driver_helper.execute(conn, 'SELECT 1')
      driver_helper.execute(conn, 'COMMIT')
    end
    gather_metrics(txn, [@wrapper_conn], txn, [@vanilla_conn], 500, 'transaction', driver_label)
  end

  # server_version is not in either wrapper's explicit dispatch (PG resolves it via method_missing to
  # the driver's server_version; MySQL via method_missing to server_info), so on the wrapper it
  # exercises the generic method_missing path, while on the native driver it is a direct call. The
  # pair isolates the method_missing dispatch cost, and works for both drivers with no setup.
  it 'method_missing performance is comparable between wrapped and vanilla drivers' do
    @wrapper_conn = driver_helper.wrapper_connect
    @vanilla_conn = driver_helper.native_connect
    target_func = ->(conn) { driver_helper.server_version(conn) }
    gather_metrics(target_func, [@wrapper_conn], target_func, [@vanilla_conn], 1000, 'method_missing', driver_label)
  end

  it 'connect performance is comparable between wrapped and vanilla drivers' do
    wrapper_func = lambda {
      conn = driver_helper.wrapper_connect
      conn&.close
    }

    vanilla_func = lambda {
      conn = driver_helper.native_connect
      conn&.close
    }
    gather_metrics(wrapper_func, [], vanilla_func, [], 100, 'connect', driver_label)
  end

  it 'connect + execute performance is comparable between wrapped and vanilla drivers' do
    wrapper_func = lambda {
      conn = driver_helper.wrapper_connect
      driver_helper.execute(conn, 'SELECT 1')
      conn&.close
    }

    vanilla_func = lambda {
      conn = driver_helper.native_connect
      driver_helper.execute(conn, 'SELECT 1')
      conn&.close
    }
    gather_metrics(wrapper_func, [], vanilla_func, [], 100, 'connect + execute', driver_label)
  end
end

RSpec.describe 'Plugin pipeline benchmarks' do
  context 'PostgreSQL' do
    include_examples 'Plugin pipeline benchmarks', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'Plugin pipeline benchmarks', MysqlTestHelper
  end
end
