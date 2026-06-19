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

require 'concurrent'
require_relative '../../logging'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      # Tracks which green host have successfully connected using a non-prefixed (blue) IAM hostname,
      # indicating the host has completed its DNS rename.
      class IamHostTracker
        include Logging

        attr_reader :green_host_change_name_times

        def initialize(on_all_changed:)
          @successful_connects = Concurrent::Hash.new
          @green_host_change_name_times = Concurrent::Hash.new
          @all_changed                 = Concurrent::AtomicBoolean.new(false)
          @on_all_changed              = on_all_changed
        end

        def register(connect_host, iam_host)
          names_differ = connect_host && connect_host != iam_host

          if names_differ && !connected?(connect_host, iam_host)
            @green_host_change_name_times[connect_host] ||= Time.now
            logger.debug { "Green host '#{connect_host}' has changed its name to '#{iam_host}'." }
          end

          (@successful_connects[connect_host] ||= Set.new).add(iam_host)

          return unless names_differ

          all_changed = @successful_connects
                        .reject { |_, v| v.empty? }
                        .all? { |k, v| v.any? { |y| k != y } }

          return unless all_changed && !@all_changed.true?

          logger.debug { 'All green hosts changed' }
          @all_changed.make_true
          @on_all_changed&.call
        end

        def connected?(connect_host, iam_host)
          @successful_connects[connect_host]&.include?(iam_host) || false
        end

        def all_changed?
          @all_changed.true?
        end

        def size
          @successful_connects.size
        end

        def clear
          @green_host_change_name_times.clear
          @all_changed.make_false
          @successful_connects.clear
        end

        def to_debug_s
          @green_host_change_name_times.map { |k, v| "   #{k} -> #{v}" }.join("\n")
        end
      end
    end
  end
end
