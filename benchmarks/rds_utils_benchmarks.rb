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

# Micro-benchmarks for RdsUtils, the regex-driven endpoint classifier. It runs on connect, on every
# host-list refresh, and while parsing connection URLs, so its cost is paid per connection rather
# than per query - but host-list refreshes are frequent enough under failover that the number is
# worth knowing.
#
# RdsUtils keeps a process-wide cache of the classification and the regex match groups keyed by host.
# That makes the cached and uncached costs differ by orders of magnitude, so a naive benchmark
# measures only the cache. Both are measured here:
#
#   - cached_hit_* : repeat lookups of one primed host, the steady state.
#   - uncached_*   : a fresh host name per invocation (a counter is part of the name), the cost paid
#     the first time an endpoint is seen. The cache is cleared periodically so it stays a miss
#     without growing without bound.
#
# The metadata extractors (region, host id, cluster id, host pattern, cluster-DNS predicates) and the
# non-cached helpers (ipv4 check, green-instance check, port stripping) are measured on their
# representative host as well.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/rds_utils.csv.
#
# Run with: bundle exec ruby benchmarks/rds_utils_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'

RdsUtils = AwsAdvancedRubyDriverWrapper::Utils::RdsUtils

# Representative host per cost centre. Each classifies to a distinct RdsUrlType, and the non-RDS host
# is the worst case for the classifier because every pattern is tried before it gives up.
INSTANCE = 'instance-1.XYZ.us-east-2.rds.amazonaws.com'
WRITER_CLUSTER = 'my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com'
READER_CLUSTER = 'my-cluster.cluster-ro-XYZ.us-east-2.rds.amazonaws.com'
CUSTOM_CLUSTER = 'my-custom.cluster-custom-XYZ.us-east-2.rds.amazonaws.com'
PROXY = 'my-proxy.proxy-XYZ.us-east-2.rds.amazonaws.com'
NON_RDS = 'my-database.example.com'
IPV4 = '10.20.30.40'

RESULTS_DIR = File.expand_path('results', __dir__)

# Bound on the uncached cache so a fresh-host-per-call run does not grow the process-wide cache
# without limit; the cache is cleared each time the counter crosses this, and every host in between
# is still a miss.
UNCACHED_CACHE_LIMIT = 50_000

# Prime the cache for the fixed hosts so the cached_hit benchmarks never include a miss.
RdsUtils.clear_cache
[INSTANCE, WRITER_CLUSTER, READER_CLUSTER, CUSTOM_CLUSTER, PROXY, NON_RDS].each do |host|
  RdsUtils.identify_rds_type(host)
end

uncached_counter = 0

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  # -- Cached-hit classification, one report per endpoint type --
  x.report('cached_hit_identify_writer_cluster') { RdsUtils.identify_rds_type(WRITER_CLUSTER) }
  x.report('cached_hit_identify_reader_cluster') { RdsUtils.identify_rds_type(READER_CLUSTER) }
  x.report('cached_hit_identify_instance') { RdsUtils.identify_rds_type(INSTANCE) }
  x.report('cached_hit_identify_custom_cluster') { RdsUtils.identify_rds_type(CUSTOM_CLUSTER) }
  x.report('cached_hit_identify_proxy') { RdsUtils.identify_rds_type(PROXY) }
  x.report('cached_hit_identify_non_rds') { RdsUtils.identify_rds_type(NON_RDS) }

  # -- Uncached classification: a fresh host per call, the first-sight cost --
  x.report('uncached_identify_instance') do
    uncached_counter += 1
    RdsUtils.clear_cache if (uncached_counter % UNCACHED_CACHE_LIMIT).zero?
    RdsUtils.identify_rds_type("instance-#{uncached_counter}.XYZ.us-east-2.rds.amazonaws.com")
  end
  x.report('uncached_identify_non_rds') do
    uncached_counter += 1
    RdsUtils.clear_cache if (uncached_counter % UNCACHED_CACHE_LIMIT).zero?
    RdsUtils.identify_rds_type("host-#{uncached_counter}.example.com")
  end

  # -- Metadata extraction (cached match groups) --
  x.report('rds_region') { RdsUtils.rds_region(INSTANCE) }
  x.report('rds_host_id') { RdsUtils.rds_host_id(INSTANCE) }
  x.report('rds_cluster_id') { RdsUtils.rds_cluster_id(WRITER_CLUSTER) }
  x.report('rds_instance_host_pattern') { RdsUtils.rds_instance_host_pattern(INSTANCE) }

  # -- Cluster-DNS predicates --
  x.report('writer_cluster_dns') { RdsUtils.writer_cluster_dns?(WRITER_CLUSTER) }
  x.report('reader_cluster_dns') { RdsUtils.reader_cluster_dns?(READER_CLUSTER) }

  # -- Non-cached helpers --
  x.report('ipv4') { RdsUtils.ip?(IPV4) }
  x.report('green_instance') { RdsUtils.green_instance?(INSTANCE) }
  x.report('remove_port') { RdsUtils.remove_port("#{INSTANCE}:5432") }

  x.compare!
end

# -- Export results for charting --

FileUtils.mkdir_p(RESULTS_DIR)

path = File.join(RESULTS_DIR, 'rds_utils.csv')
puts "\nOps/second by RdsUtils operation:\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  report.entries.each do |entry|
    ops = entry.stats.central_tendency.round
    error = entry.stats.error_percentage.round(2)
    csv << [entry.label, ops, error]
    puts "#{entry.label.ljust(36)} #{ops.to_s.rjust(12)} ops/s  (+/- #{error}%)"
  end
end

puts "\nWrote #{path}"
