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

require 'bigdecimal'
require 'date'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # The single byte written ahead of the ciphertext that records how the plaintext was
      # serialized, so that a decrypted payload can be turned back into a Ruby value.
      module TypeMarker
        STRING = 1
        INTEGER = 2
        LONG = 3
        DOUBLE = 4
        FLOAT = 5
        BOOLEAN = 6
        BIG_DECIMAL = 7
        DATE = 8
        TIME = 9
        TIMESTAMP = 10
        LOCAL_DATE = 11
        LOCAL_TIME = 12
        LOCAL_DATE_TIME = 13
        BYTE_ARRAY = 14
        GENERIC = 99

        NAMES = {
          STRING => 'STRING',
          INTEGER => 'INTEGER',
          LONG => 'LONG',
          DOUBLE => 'DOUBLE',
          FLOAT => 'FLOAT',
          BOOLEAN => 'BOOLEAN',
          BIG_DECIMAL => 'BIG_DECIMAL',
          DATE => 'DATE',
          TIME => 'TIME',
          TIMESTAMP => 'TIMESTAMP',
          LOCAL_DATE => 'LOCAL_DATE',
          LOCAL_TIME => 'LOCAL_TIME',
          LOCAL_DATE_TIME => 'LOCAL_DATE_TIME',
          BYTE_ARRAY => 'BYTE_ARRAY',
          GENERIC => 'GENERIC'
        }.freeze

        ALL = NAMES.keys.freeze

        module_function

        # @param value [Integer] the marker byte read from an encrypted payload
        # @return [Integer] the same marker, once validated
        # @raise [ArgumentError] if the byte is not a known marker
        def from_value(value)
          raise ArgumentError, "Unknown type marker: #{value.inspect}" unless NAMES.key?(value)

          value
        end

        # Picks the marker used to serialize a Ruby value. Unknown classes fall back to
        # {GENERIC}, which is serialized through +to_s+.
        #
        # Ruby has a single unbounded Integer type, so integers are always written as
        # {LONG}. {INTEGER} is still understood on read for payloads written by the wrapper.
        #
        # @param value [Object]
        # @return [Integer]
        def from_object(value)
          case value
          when String then value.encoding == ::Encoding::BINARY ? BYTE_ARRAY : STRING
          when Integer then LONG
          when Float then DOUBLE
          when true, false then BOOLEAN
          when BigDecimal then BIG_DECIMAL
          when ::Time then TIMESTAMP
          when ::DateTime then LOCAL_DATE_TIME
          when ::Date then LOCAL_DATE
          else GENERIC
          end
        end

        # @param marker [Integer]
        # @return [String, nil] the human-readable name of the marker
        def name_for(marker)
          NAMES[marker]
        end

        # @param marker [Integer]
        # @return [Boolean]
        def known?(marker)
          NAMES.key?(marker)
        end
      end
    end
  end
end
