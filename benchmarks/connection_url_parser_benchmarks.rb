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

# Per-connection URL and property parsing overhead. Everything measured here runs once per
# connection attempt, before any query is sent, so it does not affect steady-state throughput but
# does add to connection-establishment latency - which matters for short-lived connections and for
# pool warm-up where many connections open at once.
#
# The parser's cost scales with host count (each host is split and turned into a HostInfo) rather
# than URL length, so the URI and host-string entry points are measured against a single host and
# against five hosts. Query-string parsing is measured by comparing a URL with properties against
# the same URL without them.
#
# The entry points come in three families:
#   - parse_uri: full parse of a "postgresql://host:port/db?query" URL (single host, five hosts,
#     and single host with query properties).
#   - parse_conninfo: full parse of a libpq "key=value" string (with and without extra properties).
#   - string_to_host_info / host_port_from_uri: the host-splitting helpers parse_uri leans on,
#     measured in isolation against a single host and five hosts.
#
# One driver (:postgresql) is used throughout so the numbers are comparable across cases; the mysql2
# path differs only in whether it accepts URI strings, not in how a given string is split.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/connection_url_parser.csv.
#
# Run with: bundle exec ruby benchmarks/connection_url_parser_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

Parser = Utils::ConnectionConfigParser
DRIVER = :postgresql
RESULTS_DIR = File.expand_path('results', __dir__)

# Representative inputs, shaped like real Aurora/RDS endpoints.
SINGLE_HOST_URL = 'postgresql://my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com:5432/postgres'
FIVE_HOSTS = (1..5).map { |i| "instance-#{i}.XYZ.us-east-2.rds.amazonaws.com:5432" }.join(',')
FIVE_HOSTS_URL = "postgresql://#{FIVE_HOSTS}/postgres".freeze
URL_WITH_PROPERTIES =
  "#{SINGLE_HOST_URL}?user=someUser&password=somePassword&wrapper_plugins=failover" \
  '&connect_timeout=10&application_name=benchmark'.freeze

CONNINFO = 'host=my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com port=5432 dbname=postgres'
CONNINFO_WITH_PROPERTIES = "#{CONNINFO} user=someUser password=somePassword connect_timeout=10".freeze

# The host section of the single-host URL, as parse_uri hands it to string_to_host_info.
SINGLE_HOST_SECTION = 'my-cluster.cluster-XYZ.us-east-2.rds.amazonaws.com:5432'
HOST_PORT_PAIR = 'instance-1.XYZ.us-east-2.rds.amazonaws.com:5432'

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  x.report('parse_uri:single_host') { Parser.parse_uri(DRIVER, SINGLE_HOST_URL) }
  x.report('parse_uri:five_hosts') { Parser.parse_uri(DRIVER, FIVE_HOSTS_URL) }
  x.report('parse_uri:single_host_with_props') { Parser.parse_uri(DRIVER, URL_WITH_PROPERTIES) }

  x.report('parse_conninfo:basic') { Parser.parse_conninfo(DRIVER, CONNINFO) }
  x.report('parse_conninfo:with_props') { Parser.parse_conninfo(DRIVER, CONNINFO_WITH_PROPERTIES) }

  x.report('string_to_host_info:single_host') { Parser.string_to_host_info(SINGLE_HOST_SECTION) }
  x.report('string_to_host_info:five_hosts') { Parser.string_to_host_info(FIVE_HOSTS) }
  x.report('host_port_from_uri:single') { Parser.host_port_from_uri(HOST_PORT_PAIR) }

  x.compare!
end

# -- Export one CSV with a row per benchmarked entry point --

FileUtils.mkdir_p(RESULTS_DIR)

path = File.join(RESULTS_DIR, 'connection_url_parser.csv')
puts "\nOps/Second by parser entry point:\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  report.entries.each do |entry|
    ops = entry.stats.central_tendency.round
    error = entry.stats.error_percentage.round(2)
    csv << [entry.label, ops, error]
    puts "#{entry.label.ljust(34)} ops=#{ops.to_s.rjust(10)}  error=#{error}%"
  end
end

puts "\nWrote #{path}"
