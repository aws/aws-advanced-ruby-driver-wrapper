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

module AwsRubyDatabaseDriverWrapper
  module Plugins
    class FailoverPlugin
      def initialize(service_container, props = ::Concurrent::Map.new)
        @service_container = service_container
        @props = props
        @subscribed_methods = Set['connect'] | service_container.dialect_service.driver_dialect.network_bound_methods
      end

      attr_reader :subscribed_methods

      def connect(_host_info, _props, _is_initial_connection, pipeline_callable)
        @conn = pipeline_callable.call
        @conn
      end

      def execute(_target_method_name, pipeline_callable, *args, **_options)
        raise Errors::FailoverFailedError if args.any? && args[0].respond_to?(:downcase) && args[0].downcase == 'simulate failover_failed'

        raise Errors::FailoverSuccessError if args.any? && args[0].respond_to?(:downcase) && args[0].downcase == 'simulate failover_success'

        pipeline_callable.call
      end
    end
  end
end
