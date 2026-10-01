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
require_relative '../property_definition'
require_relative '../logging'

module AwsAdvancedRubyDriverWrapper
  module Utils
    class ConnectionConfig
      attr_accessor :wrapper_props, :driver_props, :prefixed_wrapper_config, :prefixed_driver_config, :initial_host_info, :driver_name
      attr_reader :original_host, :original_port

      def initialize(wrapper_props: ::Concurrent::Map.new,
                     driver_props: ::Concurrent::Map.new,
                     prefixed_wrapper_config: ::Concurrent::Map.new,
                     prefixed_driver_config: ::Concurrent::Map.new,
                     initial_host_info: nil,
                     driver_name: nil,
                     original_host: nil,
                     original_port: nil,
                     multi_host_url: false)
        @wrapper_props = wrapper_props
        @driver_props = driver_props
        @prefixed_wrapper_config = prefixed_wrapper_config
        @prefixed_driver_config = prefixed_driver_config
        @initial_host_info = initial_host_info
        @driver_name = driver_name
        @original_host = original_host
        @original_port = original_port
        @multi_host_url = multi_host_url
      end

      def multi_host_url?
        @multi_host_url
      end

      def cluster_id
        PropertyDefinition::CLUSTER_ID.get(wrapper_props)
      end

      # Redact sensitive property values (passwords, IAM tokens, Secrets Manager
      # credentials) so they are never exposed if a config is logged, interpolated,
      # or rendered in a backtrace. The property maps are the only fields that carry
      # secrets; the rest are host/driver metadata that is safe to show.
      #
      # Most secrets are recognized by name. The IAM token is passed under a property
      # whose name is configurable, so whatever name is configured is redacted too.
      def inspect
        "#<#{self.class.name} " \
          "wrapper_props=#{masked(wrapper_props)}, " \
          "driver_props=#{masked(driver_props)}, " \
          "prefixed_wrapper_config=#{masked(prefixed_wrapper_config)}, " \
          "prefixed_driver_config=#{masked(prefixed_driver_config)}, " \
          "initial_host_info=#{initial_host_info.inspect}, driver_name=#{driver_name.inspect}, " \
          "original_host=#{original_host.inspect}, original_port=#{original_port.inspect}, " \
          "multi_host_url=#{@multi_host_url.inspect}>"
      end
      alias to_s inspect

      # `pp` / PrettyPrint does not call #inspect; route them through the redacted
      # representation so `pp config` cannot leak credentials.
      def pretty_print(pp)
        pp.text(inspect)
      end

      private

      def masked(props)
        AwsAdvancedRubyDriverWrapper.mask_properties(props, [iam_token_property_name])
      end

      def iam_token_property_name
        wrapper_props && PropertyDefinition::IAM_ACCESS_TOKEN_PROPERTY_NAME.get(wrapper_props)
      end
    end
  end
end
