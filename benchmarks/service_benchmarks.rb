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

# Measures the per-call service methods on the hottest path in the wrapper. Every wrapped operation
# and every plugin reaches these, so their own cost is worth isolating. Service responsibilities are
# split across the connection, host, session state, and plugin manager services, plus the driver
# error handlers, and each is exercised here through its real implementation with only dialect
# detection and the driver connection stubbed out.
#
# What is measured:
#   - ConnectionService: current_connection and current_host_info (field reads, the floor).
#   - HostService: all_hosts (field read); hosts with and without a custom-endpoint allow list (a
#     storage lookup on every call, plus filtering when an entry exists); select_host (host
#     selection); set_availability (topology scan plus an availability-cache write).
#   - SessionStateService: in_transaction? (field read); reset; update_transaction_state (the
#     statement classification that runs on every query to track transaction boundaries).
#   - PluginManager: current_call_context (the thread-local read done once per call).
#   - PgErrorHandler: network_error_by_sql_state? for a matching and a non-matching SQLSTATE.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/services.csv with name, ops_per_second, and error_percent.
#
# Run with: bundle exec ruby benchmarks/services_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require_relative 'support/service_fixtures'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

RESULTS_DIR = File.expand_path('results', __dir__)

plain = Benchmarks::PluginServiceFixtures.build(with_allow_list: false)
allow_list = Benchmarks::PluginServiceFixtures.build(with_allow_list: true)

connection_service = plain.connection_service
host_service = plain.host_service
session_state_service = plain.session_state_service
plugin_manager = plain.plugin_manager
error_handler = plain.error_handler
all_hosts = host_service.all_hosts
reader_host = plain.reader_host

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  x.report('connection_service.current_connection') { connection_service.current_connection }
  x.report('connection_service.current_host_info') { connection_service.current_host_info }

  x.report('host_service.all_hosts') { host_service.all_hosts }
  x.report('host_service.hosts (no permissions)') { host_service.hosts }
  x.report('host_service.hosts (allow list)') { allow_list.host_service.hosts }
  x.report('host_service.select_host') { host_service.select_host(all_hosts, Host::HostRole::READER, 'random') }
  x.report('host_service.set_availability') { host_service.set_availability(reader_host, Host::HostAvailability::AVAILABLE) }

  x.report('session_state_service.in_transaction?') { session_state_service.in_transaction? }
  x.report('session_state_service.reset') { session_state_service.reset }
  x.report('session_state_service.update_transaction_state') do
    session_state_service.update_transaction_state('connection.query', ['SELECT 1'], true)
  end

  x.report('plugin_manager.current_call_context') { plugin_manager.current_call_context }

  x.report('error_handler.network_error_by_sql_state? (match)') { error_handler.network_error_by_sql_state?('08006') }
  x.report('error_handler.network_error_by_sql_state? (no match)') { error_handler.network_error_by_sql_state?('00000') }

  x.compare!
end

# -- Export one row per benchmarked method --

FileUtils.mkdir_p(RESULTS_DIR)

path = File.join(RESULTS_DIR, 'services.csv')
puts "\nOps/second by service method:\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  report.entries.each do |entry|
    ops = entry.stats.central_tendency.round
    error = entry.stats.error_percentage.round(2)
    csv << [entry.label, ops, error]
    puts "#{entry.label.ljust(52)} #{ops.to_s.rjust(12)} ops/s  (+/- #{error}%)"
  end
end

puts "\nWrote #{path}"

plain.shutdown
allow_list.shutdown
