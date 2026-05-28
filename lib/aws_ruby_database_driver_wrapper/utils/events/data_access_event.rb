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

module AwsRubyDatabaseDriverWrapper
  module Utils
    module Events
      # Event indicating data was accessed. Batched delivery (not immediate).
      class DataAccessEvent
        attr_reader :data_type, :key

        def initialize(data_type:, key:)
          @data_type = data_type
          @key = key
          freeze
        end

        def immediate_delivery?
          false
        end

        def eql?(other)
          other.instance_of?(self.class) &&
            @data_type == other.data_type &&
            @key == other.key
        end

        def hash
          [self.class, @data_type, @key].hash
        end

        alias == eql?
      end
    end
  end
end
