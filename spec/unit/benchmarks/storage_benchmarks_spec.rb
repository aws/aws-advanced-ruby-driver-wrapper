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

require_relative '../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/expiration_cache'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/sliding_expiration_cache'
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'

# Guards the assumptions the storage benchmark relies on: the cache and storage-service methods it
# calls, and the hit/miss/put behavior it counts on. The benchmark itself is not run in CI, so if a
# cache method is renamed or its semantics drift, these examples fail here instead of the benchmark
# silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe 'storage benchmark contract' do
    let(:ttl_seconds) { 300 }
    let(:hot_key) { 'key-0' }
    let(:topology_cache) { :topology }
    let(:topology) do
      Array.new(5) { |i| Host::HostInfo.new(host: "instance-#{i}.XYZ.us-east-2.rds.amazonaws.com", port: '5432') }
    end

    describe Utils::Storage::ExpirationCache do
      subject(:cache) { described_class.new(ttl: ttl_seconds) }

      before { cache.put(hot_key, 'value-0') }

      it 'returns the stored value on a get hit' do
        expect(cache.get(hot_key)).to eq('value-0')
      end

      it 'returns nil on a get miss' do
        expect(cache.get('absent')).to be_nil
      end

      it 'stores a value on put' do
        cache.put('key-1', 'value-1')
        expect(cache.get('key-1')).to eq('value-1')
      end

      it 'sweeps expired entries without touching live ones' do
        expired = described_class.new(ttl: -1)
        expired.put('stale', 'gone')
        cache.remove_expired_entries
        expired.remove_expired_entries
        expect(cache.get(hot_key)).to eq('value-0')
        expect(expired.get('stale')).to be_nil
      end
    end

    describe Utils::Storage::SlidingExpirationCache do
      subject(:cache) { described_class.new(ttl: ttl_seconds) }

      before { cache.compute_if_absent(hot_key) { 'value-0' } }

      it 'returns the stored value on a get hit' do
        expect(cache.get(hot_key)).to eq('value-0')
      end

      it 'returns nil on a get miss' do
        expect(cache.get('absent')).to be_nil
      end

      it 'returns the existing value from compute_if_absent on a hit' do
        computed = false
        result = cache.compute_if_absent(hot_key) do
          computed = true
          'other'
        end
        expect(result).to eq('value-0')
        expect(computed).to be(false)
      end

      it 'computes and stores a value from compute_if_absent on a miss' do
        expect(cache.compute_if_absent('key-1') { 'value-1' }).to eq('value-1')
        expect(cache.get('key-1')).to eq('value-1')
      end
    end

    describe Utils::Storage::StorageService do
      subject(:service) { described_class.new(event_publisher: publisher, cleanup_interval: 9999) }

      let(:publisher) { double('event_publisher', publish: nil) }

      before do
        service.register(topology_cache, ttl: ttl_seconds)
        service.set(topology_cache, hot_key, topology)
      end

      after { service.shutdown }

      it 'returns the stored topology on a get hit and publishes an access event' do
        expect(service.get(topology_cache, hot_key)).to eq(topology)
        expect(publisher).to have_received(:publish).once
      end

      it 'returns the stored topology without publishing when access registration is off' do
        expect(service.get(topology_cache, hot_key, register_access: false)).to eq(topology)
        expect(publisher).not_to have_received(:publish)
      end

      it 'returns nil on a get miss' do
        expect(service.get(topology_cache, 'absent')).to be_nil
      end

      it 'reports existence of a live entry' do
        expect(service.exists?(topology_cache, hot_key)).to be(true)
        expect(service.exists?(topology_cache, 'absent')).to be(false)
      end

      it 'stores a topology on set' do
        service.set(topology_cache, 'key-1', topology)
        expect(service.get(topology_cache, 'key-1', register_access: false)).to eq(topology)
      end
    end
  end
end
