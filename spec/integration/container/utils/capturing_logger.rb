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

require 'logger'
require 'stringio'

module Integration
  # Test-only logger that captures all log output into a StringIO buffer while
  # delegating to the original logger (preserving console output). Supports
  # real-time subscribers for log-watching threads (e.g., BG readiness detection).
  #
  # Usage:
  #   original = AwsRubyDatabaseDriverWrapper.logger
  #   capturing = Integration::CapturingLogger.new(original)
  #   AwsRubyDatabaseDriverWrapper.logger = capturing
  #   # ... run test ...
  #   AwsRubyDatabaseDriverWrapper.logger = original
  #
  class CapturingLogger < Logger
    attr_reader :captured_output

    def initialize(original_logger)
      @original_logger = original_logger
      @captured_output = StringIO.new
      @subscribers = []
      @subscriber_mutex = Mutex.new
      super(@captured_output)
      self.level = original_logger.level
      self.formatter = original_logger.formatter
    end

    def add(severity, message = nil, progname = nil, &block)
      # Write to capture buffer
      super

      # Delegate to original logger (console output)
      @original_logger.add(severity, message, progname, &block)

      # Notify subscribers
      msg = if block
              yield
            elsif message
              message
            else
              progname
            end
      notify_subscribers(severity, msg.to_s)
    end

    def add_subscriber(callable)
      @subscriber_mutex.synchronize { @subscribers << callable }
    end

    def remove_subscriber(callable)
      @subscriber_mutex.synchronize { @subscribers.delete(callable) }
    end

    def clear_captured_output
      @captured_output.truncate(0)
      @captured_output.rewind
    end

    private

    def notify_subscribers(severity, message)
      subscribers = @subscriber_mutex.synchronize { @subscribers.dup }
      subscribers.each do |subscriber|
        subscriber.call(severity, message)
      rescue StandardError
        # Don't let subscriber errors crash the logger
      end
    end
  end
end
