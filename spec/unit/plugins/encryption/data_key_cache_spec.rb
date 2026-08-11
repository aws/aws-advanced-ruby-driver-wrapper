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

require_relative '../../../spec_helper'
require 'aws_ruby_database_driver_wrapper/plugins/encryption/data_key_cache'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::DataKeyCache do
  let(:data_key) { 'a' * 32 }

  # Every cache is shut down so that its cleanup thread does not outlive the example.
  def build_cache(max_size: 10, ttl_sec: 3600, enabled: true)
    cache = described_class.new(max_size: max_size, ttl_sec: ttl_sec, enabled: enabled)
    @caches << cache
    cache
  end

  before { @caches = [] }

  after { @caches.each(&:shutdown) }

  describe 'when it is enabled' do
    subject(:cache) { build_cache }

    it 'says so' do
      expect(cache.enabled?).to be(true)
    end

    it 'returns a stored data key' do
      cache.put('datakey_abc', data_key)
      expect(cache.get('datakey_abc')).to eq(data_key)
    end

    it 'misses on a key it does not hold' do
      expect(cache.get('datakey_missing')).to be_nil
    end

    # The caller wipes its copy of the plaintext key once the value is encrypted, so the cache
    # cannot hand out the string it holds.
    it 'hands out a copy, so a caller wiping its key does not empty the cache' do
      cache.put('datakey_abc', data_key)
      borrowed = cache.get('datakey_abc')
      expect(borrowed).not_to be(data_key)

      AwsRubyDatabaseDriverWrapper::Plugins::Encryption::EncryptionService.wipe(borrowed)
      expect(cache.get('datakey_abc')).to eq(data_key)
    end

    it 'stores a copy, so a caller wiping its key does not empty the cache either' do
      mutable = +'a' * 32
      cache.put('datakey_abc', mutable)
      AwsRubyDatabaseDriverWrapper::Plugins::Encryption::EncryptionService.wipe(mutable)

      expect(cache.get('datakey_abc')).to eq('a' * 32)
    end

    it 'replaces an entry that is put twice' do
      cache.put('datakey_abc', data_key)
      cache.put('datakey_abc', 'b' * 32)

      expect(cache.get('datakey_abc')).to eq('b' * 32)
      expect(cache.size).to eq(1)
    end

    it 'ignores a put with no data key' do
      cache.put('datakey_abc', nil)
      expect(cache.size).to eq(0)
    end

    it 'drops a single entry on request' do
      cache.put('datakey_abc', data_key)
      cache.remove('datakey_abc')
      expect(cache.get('datakey_abc')).to be_nil
    end

    it 'tolerates removing a key it does not hold' do
      expect { cache.remove('datakey_missing') }.not_to raise_error
    end

    it 'drops everything on clear' do
      cache.put('datakey_a', data_key)
      cache.put('datakey_b', data_key)
      cache.clear
      expect(cache.size).to eq(0)
    end
  end

  describe 'when it is disabled' do
    subject(:cache) { build_cache(enabled: false) }

    it 'says so' do
      expect(cache.enabled?).to be(false)
    end

    it 'stores nothing and misses every lookup' do
      cache.put('datakey_abc', data_key)
      expect(cache.get('datakey_abc')).to be_nil
      expect(cache.size).to eq(0)
    end

    # A disabled cache is not a cache with a 100% miss rate: it is not consulted at all.
    it 'does not count the lookups it never made' do
      cache.get('datakey_abc')
      expect(cache.stats.misses).to eq(0)
    end

    it 'can still be shut down' do
      expect { cache.shutdown }.not_to raise_error
    end
  end

  describe 'expiry' do
    it 'misses an entry that has outlived its TTL' do
      cache = build_cache(ttl_sec: 0)
      cache.put('datakey_abc', data_key)

      expect(cache.get('datakey_abc')).to be_nil
      expect(cache.stats.misses).to eq(1)
      expect(cache.size).to eq(0)
    end

    it 'keeps an entry that is still fresh' do
      cache = build_cache(ttl_sec: 3600)
      cache.put('datakey_abc', data_key)

      expect(cache.remove_expired_entries).to eq(0)
      expect(cache.get('datakey_abc')).to eq(data_key)
    end

    it 'sweeps every expired entry' do
      cache = build_cache(ttl_sec: 0)
      cache.put('datakey_a', data_key)
      cache.put('datakey_b', data_key)

      expect(cache.remove_expired_entries).to eq(2)
      expect(cache.size).to eq(0)
    end

    describe described_class::CacheEntry do
      it 'expires once the TTL has passed' do
        entry = described_class.new(data_key: 'a' * 32, created_at: 100.0)
        expect(entry.expired?(10, 109.9)).to be(false)
        expect(entry.expired?(10, 110.0)).to be(true)
      end
    end
  end

  describe 'eviction' do
    it 'evicts the oldest key to stay within its size limit' do
      cache = build_cache(max_size: 2)
      cache.put('datakey_a', 'a' * 32)
      cache.put('datakey_b', 'b' * 32)
      cache.put('datakey_c', 'c' * 32)

      expect(cache.size).to eq(2)
      expect(cache.get('datakey_a')).to be_nil
      expect(cache.get('datakey_b')).to eq('b' * 32)
      expect(cache.get('datakey_c')).to eq('c' * 32)
    end

    it 'counts the evictions' do
      cache = build_cache(max_size: 1)
      cache.put('datakey_a', 'a' * 32)
      cache.put('datakey_b', 'b' * 32)

      expect(cache.stats.evictions).to eq(1)
    end
  end

  describe '#stats' do
    it 'counts hits and misses' do
      cache = build_cache
      cache.put('datakey_abc', data_key)
      cache.get('datakey_abc')
      cache.get('datakey_missing')

      stats = cache.stats
      expect(stats.size).to eq(1)
      expect(stats.hits).to eq(1)
      expect(stats.misses).to eq(1)
      expect(stats.hit_rate).to eq(50.0)
    end

    it 'reports a zero hit rate before anything is looked up' do
      expect(build_cache.stats.hit_rate).to eq(0.0)
    end

    it 'renders the counters for the log' do
      expect(described_class::CacheStats.new(size: 1, hits: 3, misses: 1, evictions: 0).to_s)
        .to eq('CacheStats{size=1, hits=3, misses=1, evictions=0, hit_rate=75.00%}')
    end
  end

  describe '#shutdown' do
    it 'stops the cleanup thread and empties the cache' do
      cache = build_cache
      cache.put('datakey_abc', data_key)
      cache.shutdown

      expect(cache.size).to eq(0)
    end

    it 'can be called twice' do
      cache = build_cache
      cache.shutdown
      expect { cache.shutdown }.not_to raise_error
    end
  end
end
