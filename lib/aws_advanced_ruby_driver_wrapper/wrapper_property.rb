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

module AwsAdvancedRubyDriverWrapper
  class WrapperProperty
    attr_reader :name, :default_value, :description, :type

    def initialize(name, description, default_value: nil, type: nil, validator: nil)
      @name = name.to_sym
      @description = description
      @default_value = default_value
      @type = type
      @validator = validator
    end

    # @param default [Object] used instead of the property's default when the key is in neither +props+ nor +override+
    # @return [String, Boolean, Integer, Float, nil] the value from props, or the property's default
    def get(props, override = nil, default: @default_value)
      override&.key?(@name) ? override.fetch(@name, default) : props.fetch(@name, default)
    end

    def get_bool(props, override = nil)
      val = get(props, override)
      return val if val.is_a?(TrueClass) || val.is_a?(FalseClass)

      val.to_s.downcase == 'true'
    end

    def get_int(props, override = nil)
      val = get(props, override)
      val.is_a?(Integer) ? val : val.to_i
    end

    # @param default [Object] used instead of the property's default when the key is in neither +props+ nor +override+
    # @return [Float]
    def get_float(props, override = nil, default: @default_value)
      val = get(props, override, default: default)
      val.is_a?(Float) ? val : val.to_f
    end

    def get_string(props, override = nil)
      val = get(props, override)
      val&.to_s
    end

    def validate!(value)
      @validator&.call(value, @name)
    end

    def set(props, value)
      props.put(@name, value)
    end
  end
end
