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
require 'aws_advanced_ruby_driver_wrapper/utils/storage/storage_service'
require 'aws_advanced_ruby_driver_wrapper/utils/events/batching_event_publisher'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::Storage::StorageService do
  let(:event_publisher) { AwsAdvancedRubyDriverWrapper::Utils::Events::BatchingEventPublisher.new(message_interval_sec: 9999) }

  # Use a large cleanup interval so the thread doesn't interfere with most tests.
  subject(:service) { described_class.new(event_publisher: event_publisher, cleanup_interval: 9999) }

  after do
    service.shutdown
    event_publisher.release_resources
  end

  describe '#register' do
    it 'registers a cache' do
      service.register(:test, ttl: 60)
      service.set(:test, :key, 'value')
      expect(service.get(:test, :key)).to eq('value')
    end

    it 'is a no-op if already registered' do
      service.register(:test, ttl: 60)
      service.set(:test, :key, 'first')
      service.register(:test, ttl: 1)
      expect(service.get(:test, :key)).to eq('first')
    end
  end

  describe '#set and #get' do
    before { service.register(:data, ttl: 1) }

    it 'stores and retrieves a value' do
      service.set(:data, :a, 'hello')
      expect(service.get(:data, :a)).to eq('hello')
    end

    it 'returns nil for a missing key' do
      expect(service.get(:data, :missing)).to be_nil
    end

    it 'returns nil for an expired item' do
      short_service = described_class.new(event_publisher: event_publisher, cleanup_interval: 9999)
      short_service.register(:short, ttl: 0.05)
      short_service.set(:short, :a, 'value')
      sleep(0.1)
      expect(short_service.get(:short, :a)).to be_nil
    ensure
      short_service&.shutdown
    end

    it 'raises ArgumentError for unregistered name' do
      expect { service.get(:unknown, :key) }.to raise_error(ArgumentError, /not registered/)
      expect { service.set(:unknown, :key, 'v') }.to raise_error(ArgumentError, /not registered/)
    end
  end

  describe '#exists?' do
    before { service.register(:data, ttl: 0.05) }

    it 'returns true for existing non-expired item' do
      service.set(:data, :a, 'value')
      expect(service.exists?(:data, :a)).to be true
    end

    it 'returns false for missing key' do
      expect(service.exists?(:data, :missing)).to be false
    end

    it 'returns false for expired item' do
      service.set(:data, :a, 'value')
      sleep(0.1)
      expect(service.exists?(:data, :a)).to be false
    end
  end

  describe '#remove' do
    it 'removes and returns nil on subsequent get' do
      service.register(:data, ttl: 60)
      service.set(:data, :a, 'hello')
      service.remove(:data, :a)
      expect(service.get(:data, :a)).to be_nil
    end
  end

  describe '#clear' do
    it 'removes all items for a name' do
      service.register(:data, ttl: 60)
      service.set(:data, :a, 1)
      service.set(:data, :b, 2)
      service.clear(:data)
      expect(service.size(:data)).to eq(0)
    end
  end

  describe '#clear_all' do
    it 'clears all registered caches' do
      service.register(:a, ttl: 60)
      service.register(:b, ttl: 60)
      service.set(:a, :key, 1)
      service.set(:b, :key, 2)
      service.clear_all
      expect(service.size(:a)).to eq(0)
      expect(service.size(:b)).to eq(0)
    end
  end

  describe '#size' do
    it 'returns the number of items' do
      service.register(:data, ttl: 60)
      service.set(:data, :a, 1)
      service.set(:data, :b, 2)
      expect(service.size(:data)).to eq(2)
    end
  end

  describe 'cleanup thread' do
    it 'removes expired items after interval' do
      svc = described_class.new(event_publisher: event_publisher, cleanup_interval: 0.05)
      svc.register(:data, ttl: 0.05)
      svc.set(:data, :a, 'value')
      sleep(0.2)
      expect(svc.size(:data)).to eq(0)
    ensure
      svc&.shutdown
    end

    it 'does not remove non-expired items' do
      svc = described_class.new(event_publisher: event_publisher, cleanup_interval: 0.05)
      svc.register(:data, ttl: 60)
      svc.set(:data, :a, 'value')
      sleep(0.15)
      expect(svc.size(:data)).to eq(1)
    ensure
      svc&.shutdown
    end
  end

  describe '#shutdown' do
    it 'stops the cleanup thread' do
      svc = described_class.new(event_publisher: event_publisher, cleanup_interval: 0.05)
      svc.shutdown
      thread = svc.instance_variable_get(:@cleanup_thread)
      expect(thread.alive?).to be false
    end
  end
end
