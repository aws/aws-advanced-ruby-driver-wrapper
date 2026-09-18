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

# Benchmarks for the wrapper's caching layer: ExpirationCache, SlidingExpirationCache and
# StorageService. These caches sit in front of topology lookups, monitor registries, and
# blue/green status, so they are read on connect, on every host-list refresh and by every
# monitoring tick.
#
# Two properties matter here:
#   - Some reads mutate. SlidingExpirationCache#get and #compute_if_absent extend the entry's expiry,
#     so a read takes a write path. ExpirationCache#get is a plain read that only mutates on a miss
#     (it deletes the expired entry). The gap between the two is the cost of renewal.
#   - Cleanup walks the whole map. ExpirationCache#remove_expired_entries sweeps every entry; that
#     sweep is what the StorageService background thread runs periodically, so it is priced on its
#     own rather than folded into a read.
#
# Caches are filled to ENTRY_COUNT entries so bin collisions and sweep costs are representative
# rather than measuring a one-entry map.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/storage.csv (name, ops_per_second, error_percent).
#
# Run with: bundle exec ruby benchmarks/storage_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/expiration_cache'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/sliding_expiration_cache'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

ENTRY_COUNT = 100
TTL_SECONDS = 300
HOT_KEY = 'key-0'
TOPOLOGY_CACHE = :topology
RESULTS_DIR = File.expand_path('results', __dir__)

# A publisher that discards every event, so the StorageService read path is measured without the
# cost of a real event pipeline (which is benchmarked elsewhere).
class NoOpEventPublisher
  def publish(_event); end
end

KEYS = Array.new(ENTRY_COUNT) { |i| "key-#{i}" }.freeze

def build_topology
  Array.new(5) do |i|
    Host::HostInfo.new(host: "instance-#{i}.XYZ.us-east-2.rds.amazonaws.com", port: '5432')
  end
end

topology = build_topology

# ExpirationCache: fixed TTL, no renewal on read.
expiration_cache = Utils::Storage::ExpirationCache.new(ttl: TTL_SECONDS)

# SlidingExpirationCache: renews the entry's expiry on read, so its #get is the read-that-writes
# variant and its #compute_if_absent renews on a hit.
sliding_cache = Utils::Storage::SlidingExpirationCache.new(ttl: TTL_SECONDS)

# StorageService: a named-partition registry over ExpirationCache, with a background cleanup thread.
storage_service = Utils::Storage::StorageService.new(event_publisher: NoOpEventPublisher.new, cleanup_interval: 9999)
storage_service.register(TOPOLOGY_CACHE, ttl: TTL_SECONDS)

KEYS.each_with_index do |key, i|
  value = "value-#{i}"
  expiration_cache.put(key, value)
  sliding_cache.compute_if_absent(key) { value }
  storage_service.set(TOPOLOGY_CACHE, key, topology)
end

# A rotating cursor over the populated keys, so successive iterations hit different entries rather
# than replaying one hot key.
cursor = 0
next_key = lambda do
  key = KEYS[cursor % ENTRY_COUNT]
  cursor += 1
  key
end

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  # -- ExpirationCache --
  x.report('expiration_cache_get_hit') { expiration_cache.get(next_key.call) }
  x.report('expiration_cache_get_miss') { expiration_cache.get('absent') }
  x.report('expiration_cache_put') { expiration_cache.put(next_key.call, 'value') }
  # The full-map sweep the StorageService cleanup thread runs; priced on its own, not folded into a read.
  x.report('expiration_cache_remove_expired_entries_sweep') { expiration_cache.remove_expired_entries }

  # -- SlidingExpirationCache (renew-on-read) --
  x.report('sliding_cache_get_hit') { sliding_cache.get(next_key.call) }
  x.report('sliding_cache_get_miss') { sliding_cache.get('absent') }
  x.report('sliding_cache_compute_if_absent_hit') { sliding_cache.compute_if_absent(HOT_KEY) { 'value' } }

  # -- StorageService --
  x.report('storage_service_get_topology') { storage_service.get(TOPOLOGY_CACHE, next_key.call) }
  x.report('storage_service_get_topology_no_data_access') do
    storage_service.get(TOPOLOGY_CACHE, next_key.call, register_access: false)
  end
  x.report('storage_service_get_miss') { storage_service.get(TOPOLOGY_CACHE, 'absent') }
  x.report('storage_service_exists') { storage_service.exists?(TOPOLOGY_CACHE, HOT_KEY) }
  x.report('storage_service_set_topology') { storage_service.set(TOPOLOGY_CACHE, next_key.call, topology) }

  x.compare!
end

# The StorageService owns a background cleanup thread; leaving it running keeps the process alive.
storage_service.shutdown

# -- Export one CSV row per benchmarked operation --

FileUtils.mkdir_p(RESULTS_DIR)

path = File.join(RESULTS_DIR, 'storage.csv')
puts "\nOps/second by operation:\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  report.entries.each do |entry|
    ops = entry.stats.central_tendency.round
    error = entry.stats.error_percentage.round(2)
    csv << [entry.label, ops, error]
    puts "#{entry.label.ljust(46)} #{ops.to_s.rjust(12)} ops/s  (+/- #{error}%)"
  end
end

puts "\nWrote #{path}"
