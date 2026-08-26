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
require 'aws_ruby_driver_wrapper/utils/events/batching_event_publisher'
require 'aws_ruby_driver_wrapper/utils/events/data_access_event'
require 'aws_ruby_driver_wrapper/utils/events/monitor_reset_event'

RSpec.describe AwsRubyDriverWrapper::Utils::Events::BatchingEventPublisher do
  subject(:publisher) { described_class.new(message_interval_sec: 0.1) }

  let(:subscriber) { instance_double('EventSubscriber', process_event: nil) }
  let(:data_access_event) { AwsRubyDriverWrapper::Utils::Events::DataAccessEvent.new(data_type: :topology, key: 'k1') }
  let(:monitor_reset_event) do
    AwsRubyDriverWrapper::Utils::Events::MonitorResetEvent.new(cluster_id: 'c1', endpoints: Set['host-a'])
  end

  after { publisher.release_resources }

  describe '#subscribe and #publish' do
    it 'delivers batched events after the interval' do
      publisher.subscribe(subscriber, Set[data_access_event.class])
      publisher.publish(data_access_event)

      expect(subscriber).not_to have_received(:process_event)

      sleep(0.2)

      expect(subscriber).to have_received(:process_event).with(data_access_event)
    end

    it 'deduplicates batched events' do
      publisher.subscribe(subscriber, Set[data_access_event.class])
      duplicate = AwsRubyDriverWrapper::Utils::Events::DataAccessEvent.new(data_type: :topology, key: 'k1')

      publisher.publish(data_access_event)
      publisher.publish(duplicate)

      sleep(0.2)

      expect(subscriber).to have_received(:process_event).once
    end
  end

  describe '#release_resources' do
    it 'drains remaining events before stopping' do
      publisher.subscribe(subscriber, Set[data_access_event.class])
      publisher.publish(data_access_event)
      publisher.release_resources

      expect(subscriber).to have_received(:process_event).with(data_access_event)
    end
  end
end
