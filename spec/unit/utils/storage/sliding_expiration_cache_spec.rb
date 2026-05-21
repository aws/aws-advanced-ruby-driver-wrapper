# frozen_string_literal: true

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative '../../../spec_helper'
require 'aws_ruby_database_driver_wrapper/utils/storage/sliding_expiration_cache'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::Storage::SlidingExpirationCache do
  subject(:cache) { described_class.new(ttl: 1) }

  describe '#get' do
    it 'returns nil for a missing key' do
      expect(cache.get(:missing)).to be_nil
    end

    it 'returns nil for an expired entry' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.compute_if_absent(:a) { 'value' }
      sleep(0.1)
      expect(short_cache.get(:a)).to be_nil
    end

    it 'extends expiration on access' do
      short_cache = described_class.new(ttl: 0.15)
      short_cache.compute_if_absent(:a) { 'value' }
      sleep(0.1)
      short_cache.get(:a)
      sleep(0.1)
      # 0.2s total, past original 0.15s TTL, but get renewed it
      expect(short_cache.get(:a)).to eq('value')
    end
  end

  describe '#compute_if_absent' do
    it 'computes and stores a value when key is absent' do
      result = cache.compute_if_absent(:a) { 'computed' }
      expect(result).to eq('computed')
      expect(cache.get(:a)).to eq('computed')
    end

    it 'returns existing value without calling block' do
      cache.compute_if_absent(:a) { 'first' }
      result = cache.compute_if_absent(:a) { 'second' }
      expect(result).to eq('first')
    end

    it 'passes the key to the block' do
      cache.compute_if_absent(:my_key) do |key|
        expect(key).to eq(:my_key)
        'value'
      end
    end

    it 'renews expiration on existing entries' do
      short_cache = described_class.new(ttl: 0.3)
      short_cache.compute_if_absent(:a) { 'value' }
      sleep(0.2)
      # Entry would expire at 0.3s, but this renewal resets the TTL.
      short_cache.compute_if_absent(:a) { 'new_value' }
      sleep(0.2)
      # 0.4s total elapsed, past the original 0.3s TTL, but renewal keeps it alive.
      expect(short_cache.get(:a)).to eq('value')
    end
  end

  describe '#extend_expiration' do
    it 'renews the TTL of an existing entry' do
      short_cache = described_class.new(ttl: 0.15)
      short_cache.compute_if_absent(:a) { 'value' }
      sleep(0.1)
      short_cache.extend_expiration(:a)
      sleep(0.1)
      expect(short_cache.get(:a)).to eq('value')
    end

    it 'does nothing for a missing key' do
      expect { cache.extend_expiration(:missing) }.not_to raise_error
    end
  end

  describe '#remove' do
    it 'removes and returns the value' do
      cache.compute_if_absent(:a) { 'hello' }
      expect(cache.remove(:a)).to eq('hello')
      expect(cache.get(:a)).to be_nil
    end

    it 'returns nil for a missing key' do
      expect(cache.remove(:missing)).to be_nil
    end
  end

  describe '#remove_if' do
    it 'removes when predicate is true' do
      cache.compute_if_absent(:a) { 42 }
      result = cache.remove_if(:a) { |v| v == 42 }
      expect(result).to eq(42)
      expect(cache.get(:a)).to be_nil
    end

    it 'does not remove when predicate is false' do
      cache.compute_if_absent(:a) { 42 }
      result = cache.remove_if(:a) { |v| v == 99 }
      expect(result).to be_nil
      expect(cache.get(:a)).to eq(42)
    end

    it 'returns nil for a missing key' do
      result = cache.remove_if(:missing) { true }
      expect(result).to be_nil
    end
  end

  describe '#remove_expired_if' do
    it 'removes when expired and predicate is true' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.compute_if_absent(:a) { 'value' }
      sleep(0.1)
      result = short_cache.remove_expired_if(:a) { |v| v == 'value' }
      expect(result).to eq('value')
    end

    it 'does not remove when not expired' do
      cache.compute_if_absent(:a) { 'value' }
      result = cache.remove_expired_if(:a) { true }
      expect(result).to be_nil
      expect(cache.get(:a)).to eq('value')
    end

    it 'does not remove when expired but predicate is false' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.compute_if_absent(:a) { 'value' }
      sleep(0.1)
      result = short_cache.remove_expired_if(:a) { false }
      expect(result).to be_nil
    end

    it 'returns nil for a missing key' do
      result = cache.remove_expired_if(:missing) { true }
      expect(result).to be_nil
    end
  end

  describe '#entries' do
    it 'returns a hash copy of all entries including expired' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.compute_if_absent(:a) { 1 }
      short_cache.compute_if_absent(:b) { 2 }
      sleep(0.1)
      entries = short_cache.entries
      expect(entries).to eq({ a: 1, b: 2 })
    end

    it 'returns an empty hash when cache is empty' do
      expect(cache.entries).to eq({})
    end
  end

  describe 'default TTL' do
    it 'uses 900 seconds by default' do
      expect(described_class::DEFAULT_TTL).to eq(900)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent compute_if_absent without errors' do
      threads = Array.new(10) do |i|
        Thread.new do
          50.times do |j|
            key = :"key_#{j % 10}"
            cache.compute_if_absent(key) { "value_#{i}_#{j}" }
          end
        end
      end
      threads.each(&:join)

      10.times do |j|
        expect(cache.get(:"key_#{j}")).to be_a(String)
      end
    end

    it 'handles concurrent mixed operations without errors' do
      threads = Array.new(10) do |_i|
        Thread.new do
          50.times do |j|
            key = :"key_#{j % 10}"
            cache.compute_if_absent(key) { j }
            cache.get(key)
            cache.extend_expiration(key)
            cache.remove_if(key, &:even?)
            cache.entries
          end
        end
      end
      threads.each(&:join)
    end
  end
end
