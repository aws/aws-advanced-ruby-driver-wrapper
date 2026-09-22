# frozen_string_literal: true

#  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# The wrapper's own overhead, measured against the driver it wraps. Every wrapped operation has a raw
# twin that performs the identical call directly against the same fake driver connection, so the
# difference between the pair is the wrapper's contribution and the target's cost cancels.
#
# Read the pairs, not the absolute values. The target is a fake connection, not a real database, so
# absolute numbers are not a round trip; but the target is identical on both sides of every pair,
# which is what makes the difference meaningful. Plugins are excluded so this isolates the wrapper's
# own machinery (the plugin chain cost is measured in connection_plugin_manager_benchmarks).
#
# Two cost centres are covered:
#   - Per call: query, prepare, escape, ping - each goes through the plugin pipeline and, for query,
#     a result wrapper allocation.
#   - Per row: iterating a result over 1, 100, and 1000 rows, so the fixed and per-row parts separate.
#
# There is no per-parameter section: mysql2 (and pg) bind all parameters in a single execute/exec
# call rather than through per-parameter setters, so there is no equivalent to measure.
#
# Run with: bundle exec ruby benchmarks/wrapper_overhead_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/mysql'
require_relative 'support/benchmark_services'
require_relative 'support/fake_mysql2_driver'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

SQL = 'SELECT id, name FROM users WHERE id = 42'
ROW_COUNTS = { 1 => '1_row', 100 => '100_rows', 1000 => '1000_rows' }.freeze
RESULTS_DIR = File.expand_path('results', __dir__)

# Builds a WrapperMysql2Client over a fake driver connection, with a real plugin-free plugin manager,
# without opening a real connection.
def build_wrapped_client(fake_connection)
  container = Benchmarks::BenchmarkServices.container({ wrapper_plugins: '' }, current_connection: fake_connection)
  container.plugin_manager = Services::PluginManager.new(container)

  client = WrapperMysql2Client.allocate
  client.instance_variable_set(:@service_container, container)
  client.instance_variable_set(:@async_conn, nil)
  client.instance_variable_set(:@async_sql, nil)
  client.instance_variable_set(:@last_sql, nil)
  client
end

def traverse(result)
  total = 0
  result.each { |row| total += row['id'] }
  total
end

raw_client = Benchmarks::FakeMysql2Driver::FakeClient.new
wrapped_client = build_wrapped_client(raw_client)

# Per-row targets: one raw fake and one wrapped client per row count, all backed by the same fake.
raw_row_clients = ROW_COUNTS.keys.to_h { |n| [n, Benchmarks::FakeMysql2Driver::FakeClient.new(row_count: n)] }
wrapped_row_clients = raw_row_clients.transform_values { |fake| build_wrapped_client(fake) }

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  x.report('raw:query') { raw_client.query(SQL) }
  x.report('wrapped:query') { wrapped_client.query(SQL) }

  x.report('raw:prepare') { raw_client.prepare(SQL) }
  x.report('wrapped:prepare') { wrapped_client.prepare(SQL) }

  x.report('raw:escape') { raw_client.escape(SQL) }
  x.report('wrapped:escape') { wrapped_client.escape(SQL) }

  x.report('raw:ping') { raw_client.ping }
  x.report('wrapped:ping') { wrapped_client.ping }

  ROW_COUNTS.each do |count, label|
    x.report("raw:traverse_#{label}") { traverse(raw_row_clients[count].query(SQL)) }
    x.report("wrapped:traverse_#{label}") { traverse(wrapped_row_clients[count].query(SQL)) }
  end

  x.compare!
end

# -- Export the raw/wrapped pairs and the wrapper overhead per call --

FileUtils.mkdir_p(RESULTS_DIR)

ips_by_label = report.entries.to_h { |entry| [entry.label, entry.stats.central_tendency] }
operations = ips_by_label.keys.map { |label| label.split(':', 2).last }.uniq

path = File.join(RESULTS_DIR, 'wrapper_overhead.csv')
puts "\nWrapper overhead per operation:\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[operation raw_ops_per_second wrapped_ops_per_second overhead_ns_per_call]
  operations.each do |op|
    raw_ips = ips_by_label.fetch("raw:#{op}")
    wrapped_ips = ips_by_label.fetch("wrapped:#{op}")
    overhead_ns = ((1.0 / wrapped_ips) - (1.0 / raw_ips)) * 1_000_000_000
    csv << [op, raw_ips.round, wrapped_ips.round, overhead_ns.round]
    puts "#{op.ljust(20)} raw=#{raw_ips.round.to_s.rjust(9)}  wrapped=#{wrapped_ips.round.to_s.rjust(9)}  overhead=#{overhead_ns.round}ns"
  end
end

puts "\nWrote #{path}"
