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
require 'aws_ruby_driver_wrapper/utils/storage/expiration_cache'

RSpec.describe AwsRubyDriverWrapper::Utils::Storage::ExpirationCache do
  subject(:cache) { described_class.new(ttl: 1) }

  describe '#put and #get' do
    it 'stores and retrieves a value' do
      cache.put(:a, 'hello')
      expect(cache.get(:a)).to eq('hello')
    end

    it 'returns nil for a missing key' do
      expect(cache.get(:missing)).to be_nil
    end

    it 'returns the previous value on put' do
      cache.put(:a, 'first')
      expect(cache.put(:a, 'second')).to eq('first')
    end

    it 'returns nil on first put' do
      expect(cache.put(:a, 'first')).to be_nil
    end

    it 'overwrites existing values' do
      cache.put(:a, 'first')
      cache.put(:a, 'second')
      expect(cache.get(:a)).to eq('second')
    end
  end

  describe '#get with expiration' do
    it 'returns nil for expired entries' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.put(:a, 'value')
      sleep(0.1)
      expect(short_cache.get(:a)).to be_nil
    end

    it 'removes expired entries on get' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.put(:a, 'value')
      sleep(0.1)
      short_cache.get(:a)
      expect(short_cache.size).to eq(0)
    end
  end

  describe '#remove' do
    it 'removes and returns the value' do
      cache.put(:a, 'hello')
      expect(cache.remove(:a)).to eq('hello')
      expect(cache.get(:a)).to be_nil
    end

    it 'returns nil for a missing key' do
      expect(cache.remove(:missing)).to be_nil
    end
  end

  describe '#clear' do
    it 'removes all entries' do
      cache.put(:a, 1)
      cache.put(:b, 2)
      cache.clear
      expect(cache.size).to eq(0)
      expect(cache.get(:a)).to be_nil
    end
  end

  describe '#size' do
    it 'returns the number of entries including expired ones' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.put(:a, 1)
      short_cache.put(:b, 2)
      expect(short_cache.size).to eq(2)
      sleep(0.1)
      expect(short_cache.size).to eq(2)
    end
  end

  describe '#remove_expired_entries' do
    it 'removes only expired entries' do
      short_cache = described_class.new(ttl: 0.05)
      short_cache.put(:a, 'expires')
      sleep(0.1)
      short_cache.put(:b, 'fresh')
      short_cache.remove_expired_entries
      expect(short_cache.size).to eq(1)
      expect(short_cache.get(:b)).to eq('fresh')
      expect(short_cache.get(:a)).to be_nil
    end

    it 'does nothing when no entries are expired' do
      cache.put(:a, 1)
      cache.put(:b, 2)
      cache.remove_expired_entries
      expect(cache.size).to eq(2)
    end
  end

  describe 'default TTL' do
    it 'uses 300 seconds by default' do
      expect(described_class::DEFAULT_TTL).to eq(300)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent put and get without errors' do
      threads = Array.new(10) do |i|
        Thread.new do
          50.times do |j|
            key = :"key_#{j % 10}"
            cache.put(key, "value_#{i}_#{j}")
            cache.get(key)
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
            cache.put(key, j)
            cache.get(key)
            cache.remove(key)
            cache.put(key, j)
            cache.size
            cache.remove_expired_entries
          end
        end
      end
      threads.each(&:join)
    end
  end
end
