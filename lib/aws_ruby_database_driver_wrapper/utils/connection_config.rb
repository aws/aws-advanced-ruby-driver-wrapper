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

require_relative '../property_definition'

module AwsRubyDatabaseDriverWrapper
  module Utils
    class ConnectionConfig
      attr_accessor :wrapper_props, :driver_props, :prefixed_props, :initial_host_info, :driver_name,
                    :initial_args, :initial_options

      def initialize(wrapper_props: {}, driver_props: {}, prefixed_props: {}, initial_host_info: nil,
                     driver_name: nil, initial_args: [], initial_options: {}, multi_host: false)
        @wrapper_props = wrapper_props
        @driver_props = driver_props
        @prefixed_props = prefixed_props
        @initial_host_info = initial_host_info
        @driver_name = driver_name
        @initial_args = initial_args
        @initial_options = initial_options
        @multi_host = multi_host
      end

      def multi_host?
        @multi_host
      end

      def cluster_id
        PropertyDefinition::CLUSTER_ID.get(wrapper_props)
      end
    end
  end
end
