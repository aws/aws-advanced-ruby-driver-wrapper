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
        RubyMethod::CONNECT,
        RubyMethod::CONNECTION_CLOSE,
        RubyMethod::CONNECTION_PING,
        RubyMethod::CONNECTION_RESET,
        RubyMethod::CONNECTION_PREPARE,
        RubyMethod::STATEMENT_EXECUTE,
        RubyMethod::STATEMENT_CLOSE
      ].freeze

      def connect(host_info, config)
        raise NotImplementedError
      end

      # Connects using the original args/options the user passed to the wrapper.
      # Used for initial multi-host connections so the community driver handles
      # multi-host failover natively.
      #
      # @param connection_config [Utils::ConnectionConfig] the parsed connection configuration
      # @param props [Hash] additional properties to merge (e.g. IAM tokens), excluding :host and :port
      def connect_with_initial_args(connection_config, props)
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
