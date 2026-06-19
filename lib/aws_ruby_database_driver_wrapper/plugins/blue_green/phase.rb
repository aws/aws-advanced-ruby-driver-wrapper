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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    module BlueGreen
      class Phase
        include Comparable

        attr_reader :value, :name

        def initialize(value, active_switchover_or_completed, name)
          @value = value
          @active_switchover_or_completed = active_switchover_or_completed
          @name = name
        end
        private_class_method :new

        NOT_CREATED = new(0, false, 'NOT_CREATED')
        CREATED     = new(1, false, 'CREATED')
        PREPARATION = new(2, true,  'PREPARATION')
        IN_PROGRESS = new(3, true,  'IN_PROGRESS')
        POST        = new(4, true,  'POST')
        COMPLETED   = new(5, true,  'COMPLETED')

        STATUS_MAPPING = {
          'AVAILABLE' => CREATED,
          'SWITCHOVER_INITIATED' => PREPARATION,
          'SWITCHOVER_IN_PROGRESS' => IN_PROGRESS,
          'SWITCHOVER_IN_POST_PROCESSING' => POST,
          'SWITCHOVER_COMPLETED' => COMPLETED
        }.freeze

        def self.parse_phase(value)
          return NOT_CREATED if value.nil? || value.empty?

          STATUS_MAPPING.fetch(value.upcase) do
            raise ArgumentError, "Unknown Blue/Green status: #{value}"
          end
        end

        def active_switchover_or_completed?
          @active_switchover_or_completed
        end

        def to_s
          @name
        end

        def <=>(other)
          value <=> other.value
        end
      end
    end
  end
end
