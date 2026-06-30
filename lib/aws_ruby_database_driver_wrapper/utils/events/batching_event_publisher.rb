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

require_relative '../../logging'

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Events
      # Publishes batched events periodically and immediate events synchronously.
      # Batches deduplicate events via Set semantics (eql?/hash).
      #
      # Public API:
      #   subscribe(subscriber, event_classes) — register for event types
      #   unsubscribe(subscriber, event_classes) — deregister
      #   publish(event) — deliver immediate or queue batched
      #   release_resources — stop background thread
      class BatchingEventPublisher
        include Logging

        DEFAULT_MESSAGE_INTERVAL_SEC = 30

        def initialize(message_interval_sec: DEFAULT_MESSAGE_INTERVAL_SEC)
          @message_interval_sec = message_interval_sec
          @subscribers = {}
          @event_queue = Set.new
          @lock = Mutex.new
          @running = true
          @thread = start_publishing_thread
        end

        def subscribe(subscriber, event_classes)
          @lock.synchronize do
            event_classes.each do |event_class|
              (@subscribers[event_class] ||= Set.new).add(subscriber)
            end
          end
        end

        def unsubscribe(subscriber, event_classes)
          @lock.synchronize do
            event_classes.each do |event_class|
              set = @subscribers[event_class]
              next unless set

              set.delete(subscriber)
              @subscribers.delete(event_class) if set.empty?
            end
          end
        end

        def publish(event)
          if event.immediate_delivery?
            deliver_event(event)
          else
            @lock.synchronize { @event_queue.add(event) }
          end
        end

        def release_resources
          @lock.synchronize { @running = false }
          begin
            @thread&.wakeup
          rescue ThreadError
            nil
          end
          @thread&.join(@message_interval_sec)
        end

        private

        def start_publishing_thread
          thread = Thread.new do
            while @lock.synchronize { @running }
              sleep(@message_interval_sec)
              send_messages
            end
            send_messages
          end
          thread.name = 'batching-event-publisher'
          thread
        end

        def send_messages
          events = @lock.synchronize do
            batch = @event_queue.to_a
            @event_queue.clear
            batch
          end

          events.each { |event| deliver_event(event) }
        end

        def deliver_event(event)
          subscribers = @lock.synchronize { @subscribers[event.class]&.to_a }
          return unless subscribers

          subscribers.each do |subscriber|
            subscriber.process_event(event)
          rescue StandardError => e
            logger.error("Error delivering event to subscriber: #{e.message}")
          end
        end
      end
    end
  end
end
