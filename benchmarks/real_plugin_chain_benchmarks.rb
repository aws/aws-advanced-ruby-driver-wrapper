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

# Per-call cost of the wrapper's real plugins through the execute pipeline. The plugin-free
# benchmarks measure a no-op plugin chain; this one runs connection.query through a manager with
# exactly one real plugin enabled, against a no_plugins baseline that is only the terminal default
# plugin. The difference is that plugin's steady-state cost - what a query pays while nothing is
# going wrong - not failover, token fetches or topology refreshes, which are driven by network
# events and background threads rather than by execute.
#
# What the numbers mean depends on whether the plugin subscribes to connection.query:
#   - iam, secrets_manager and initial_connection subscribe only to connect (and internal_connect),
#     so through the execute pipeline they are pass-throughs and score the same as no_plugins. That
#     is the correct result: it confirms the subscription filter keeps them out of the query path.
#   - failover, gdb_failover, bg, custom_endpoint and kms_encryption subscribe to connection.query,
#     so the full chain runs and their per-call cost shows.
# default_combo is initial_connection + failover; since only failover subscribes to execute, it
# reflects the failover plugin's cost.
#
# The stub services make the terminal call constant-cost, so the figures reflect the chain's own
# cost rather than any real database work. Fake AWS credentials are set below so the auth plugins
# resolve offline at construction without a network call.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/real_plugin_chain.csv.
#
# Run with: bundle exec ruby benchmarks/real_plugin_chain_benchmarks.rb

# Set offline AWS credentials before the gem loads, so the iam and secrets_manager plugins resolve
# static credentials at construction instead of reaching out to a metadata endpoint.
ENV['AWS_ACCESS_KEY_ID'] ||= 'AKIAFAKEFAKEFAKEFAKE'
ENV['AWS_SECRET_ACCESS_KEY'] ||= 'fakefakefakefakefakefakefakefakefakefake'
ENV['AWS_REGION'] ||= 'us-east-1'

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/services/plugin_manager'
require_relative 'support/benchmark_services'
require_relative 'support/real_plugin_chain_support'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

CHAINS = Benchmarks::RealPluginChainSupport::CHAINS
RESULTS_DIR = File.expand_path('results', __dir__)

storage_services = []
managers = CHAINS.transform_values do |plugin_codes|
  Benchmarks::RealPluginChainSupport.build_manager(plugin_codes, storage_services)
end

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  CHAINS.each_key do |name|
    manager = managers.fetch(name)
    x.report(name) { Benchmarks::RealPluginChainSupport.run_execute(manager) }
  end

  x.compare!
end

# -- Export one row per chain for charting --

FileUtils.mkdir_p(RESULTS_DIR)

results_by_name = report.entries.to_h do |entry|
  [entry.label, { ops_per_second: entry.stats.central_tendency.round, error_percent: entry.stats.error_percentage.round(2) }]
end

path = File.join(RESULTS_DIR, 'real_plugin_chain.csv')
puts "\nOps/Second by plugin chain (execute pipeline):\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  CHAINS.each_key do |name|
    result = results_by_name.fetch(name)
    csv << [name, result[:ops_per_second], result[:error_percent]]
    puts "#{name.ljust(20)} ops/s=#{result[:ops_per_second].to_s.rjust(10)}  error=#{result[:error_percent]}%"
  end
end

puts "\nWrote #{path}"

# Every StorageService owns a background cleanup thread; shut them all down so the process exits.
storage_services.each(&:shutdown)
Benchmarks::RealPluginChainSupport.release_providers
