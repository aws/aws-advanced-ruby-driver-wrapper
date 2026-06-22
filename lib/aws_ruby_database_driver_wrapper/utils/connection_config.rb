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

module AwsRubyDatabaseDriverWrapper
  module Utils
    class ConnectionConfig
      attr_accessor :wrapper_props, :driver_props, :prefixed_props, :initial_host_info, :driver_name
      attr_reader :original_host, :original_port

      def initialize(wrapper_props: ::Concurrent::Map.new,
                     driver_props: ::Concurrent::Map.new,
                     prefixed_props: ::Concurrent::Map.new,
                     initial_host_info: nil,
                     driver_name: nil,
                     original_host: nil,
                     original_port: nil,
                     multi_host_url: false)
        @wrapper_props = wrapper_props
        @driver_props = driver_props
        @prefixed_props = prefixed_props
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
    end
  end
end
