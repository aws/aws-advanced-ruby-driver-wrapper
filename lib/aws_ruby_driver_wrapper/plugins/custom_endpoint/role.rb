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

module AwsRubyDriverWrapper
  module Plugins
    module CustomEndpoint
      # Represents the possible roles of instances specified by a custom endpoint.
      module Role
        # Instances may be either a writer or a reader.
        ANY = :any

        # Instance is always the writer.
        WRITER = :writer

        # Instances are always readers.
        READER = :reader

        ROLE_MAPPING = {
          'ANY' => ANY,
          'WRITER' => WRITER,
          'READER' => READER
        }.freeze

        def self.parse(value)
          raise ArgumentError, 'Role value is blank' if value.nil? || value.strip.empty?

          ROLE_MAPPING.fetch(value.upcase) { raise ArgumentError, "Unknown role: #{value}" }
        end
      end
    end
  end
end
