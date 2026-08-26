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
  class Configuration
    VALID_KEYS = %i[
      prepare_host_func
      custom_dialect
      custom_error_handler
      connection_init_func
    ].freeze

    def initialize
      @mutex = Mutex.new
      @values = {}
    end

    (VALID_KEYS - %i[prepare_host_func]).each do |key|
      define_method(key) { @mutex.synchronize { @values[key] } }
      define_method(:"#{key}=") { |val| @mutex.synchronize { @values[key] = val } }
    end

    def prepare_host_func
      Utils::RdsUtils.prepare_host_func
    end

    def prepare_host_func=(func)
      Utils::RdsUtils.prepare_host_func = func
    end

    def update(**options)
      options.each do |key, value|
        raise ArgumentError, "Unknown configuration key: #{key}" unless VALID_KEYS.include?(key)

        public_send(:"#{key}=", value)
      end
      self
    end

    def reset!
      VALID_KEYS.each { |key| public_send(:"#{key}=", nil) }
      self
    end
  end
end
