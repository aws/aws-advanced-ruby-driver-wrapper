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

# Measures how the plugin manager's per-call overhead scales with the number of plugins in the
# chain. Each pipeline is run against 0, 1, 2, 5, and 10 no-op plugins, and also against the real
# default plugins (initial connection strategy + failover). The stubbed services make the terminal
# call constant-cost, so the reported figures reflect the pipeline's own cost rather than any real
# database work.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/ as one CSV per pipeline.
#
# Run with: bundle exec ruby benchmarks/connection_plugin_manager_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require_relative 'support/benchmark_plugin'
require_relative 'support/benchmark_services'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

# The no-op plugin counts each pipeline is measured at, plus a series for the real default plugins.
PLUGIN_COUNTS = [0, 1, 2, 5, 10].freeze
DEFAULT_SERIES = 'Default'
SERIES = (PLUGIN_COUNTS + [DEFAULT_SERIES]).freeze

# The pipelines the plugin manager drives.
PIPELINES = %w[connect internal_connect execute].freeze

RESULTS_DIR = File.expand_path('results', __dir__)

# Registers the largest no-op count once; a smaller chain is just the first N of those codes.
plugin_codes = Benchmarks::BenchmarkPlugin.register(PLUGIN_COUNTS.max)

def manager_for(props)
  Services::PluginManager.new(Benchmarks::BenchmarkServices.container(props))
end

# One manager per series: the no-op chains keyed by count, plus the default-plugins chain.
managers = PLUGIN_COUNTS.to_h do |count|
  [count, manager_for(wrapper_plugins: plugin_codes.first(count).join(','))]
end
managers[DEFAULT_SERIES] = manager_for(
  wrapper_plugins: AwsAdvancedRubyDriverWrapper::PropertyDefinition::PLUGINS.default_value
)

host_info = Host::HostInfo.new(host: Benchmarks::BenchmarkServices::REALISTIC_HOST, port: '5432')
driver_props = {}
current_connection = Benchmarks::BenchmarkServices::STUB_CONNECTION
query_method = RubyMethod::CONNECTION_QUERY
target_callable = -> { 1 }

def case_label(pipeline, series)
  suffix = series == DEFAULT_SERIES ? DEFAULT_SERIES : series.to_s
  "#{pipeline}#{suffix}Plugins"
end

# The call each pipeline makes, given a manager. is_initial_connection is false so the comparison
# stays about the plugin chain: on a non-initial connect the initial connection strategy plugin is a
# pass-through, so the Default series here reflects the failover plugin's per-call cost.
def run_pipeline(pipeline, manager, host_info, driver_props, current_connection, query_method, target_callable)
  case pipeline
  when 'connect' then manager.connect(host_info, driver_props, false)
  when 'internal_connect' then manager.internal_connect(host_info, driver_props, {}, false)
  when 'execute' then manager.execute(query_method, current_connection, target_callable)
  end
end

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  PIPELINES.each do |pipeline|
    SERIES.each do |series|
      manager = managers[series]
      x.report(case_label(pipeline, series)) do
        run_pipeline(pipeline, manager, host_info, driver_props, current_connection, query_method, target_callable)
      end
    end
  end

  x.compare!
end

# -- Export one CSV per pipeline for charting --

FileUtils.mkdir_p(RESULTS_DIR)

ops_by_label = report.entries.to_h do |entry|
  [entry.label, { ops_per_second: entry.stats.central_tendency.round, error_percent: entry.stats.error_percentage.round(2) }]
end

puts "\nOps/Second by pipeline and plugin series:\n\n"
PIPELINES.each do |pipeline|
  path = File.join(RESULTS_DIR, "#{pipeline}.csv")
  CSV.open(path, 'w') do |csv|
    csv << %w[plugins ops_per_second error_percent]
    SERIES.each do |series|
      result = ops_by_label.fetch(case_label(pipeline, series))
      csv << [series, result[:ops_per_second], result[:error_percent]]
    end
  end

  row = SERIES.map { |series| "#{series}=#{ops_by_label.fetch(case_label(pipeline, series))[:ops_per_second]}" }
  puts "#{pipeline.ljust(18)} #{row.join('  ')}"
  puts "  -> #{path}"
end
