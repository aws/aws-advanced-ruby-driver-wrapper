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

require 'set'
require_relative '../ruby_method'
require_relative '../logging'

module AwsRubyDatabaseDriverWrapper
  module DriverDialects
    module DriverDialect
      include Logging

      COMMON_NETWORK_BOUND_METHODS = Set[
        RubyMethod::CONNECT.name,
        RubyMethod::CONNECTION_CLOSE.name,
        RubyMethod::CONNECTION_PING.name,
        RubyMethod::CONNECTION_RESET.name,
        RubyMethod::CONNECTION_PREPARE.name,
        RubyMethod::STATEMENT_EXECUTE.name,
        RubyMethod::STATEMENT_CLOSE.name
      ].freeze

      def connect(host_info, config)
        raise NotImplementedError
      end

      def execute(connection, sql)
        raise NotImplementedError
      end

      def ping(connection)
        raise NotImplementedError
      end

      def closed?(connection)
        raise NotImplementedError
      end

      def close_connection(connection)
        raise NotImplementedError
      end

      def sql_state(_exception)
        nil
      end

      def network_bound_methods
        COMMON_NETWORK_BOUND_METHODS
      end

      def prepare_connect_config(host_info, config)
        raise NotImplementedError
      end
    end
  end
end
