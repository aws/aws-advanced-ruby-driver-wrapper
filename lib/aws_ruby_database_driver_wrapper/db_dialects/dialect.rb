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
#  limitations under the License.class Dialect

module AwsAdvancedRubyWrapper
  module DbDialects
    module Dialect
      # Determines if the given connection is using this dialect.
      #
      # @param connection [Object] active database connection
      # @return [Boolean] true if the connection matches this dialect
      def dialect?(connection)
        raise NotImplementedError
      end

      # Returns the default port for this database dialect.
      #
      # @return [Integer]
      def default_port
        raise NotImplementedError
      end

      # Returns a list of dialect codes that this dialect may be updated to.
      #
      # @return [Array<String>] dialect code candidates
      def dialect_update_candidates
        raise NotImplementedError
      end

      # Returns the exception handler for this dialect.
      #
      # @return [ExceptionHandler]
      def exception_handler
        raise NotImplementedError
      end

      # Returns the host list provider for this dialect.
      #
      # @return [HostListProvider]
      def host_list_provider
        raise NotImplementedError
      end

      # Prepares connection properties before establishing a connection.
      #
      # @param connect_properties [Hash] properties to be used for the connection
      # @param protocol [String] connection protocol
      # @param host [Host::HostInfo] target host
      def prepare_connect_properties(connect_properties, protocol, host)
        raise NotImplementedError
      end

      # Returns the set of failover restrictions for this dialect.
      #
      # @return [Array<Symbol>] failover restrictions
      def failover_restrictions
        raise NotImplementedError
      end

      # Returns the host ID and hostname for the given connection.
      #
      # @param connection [Object] active database connection
      # @return [Array(String, String), nil] pair of [hostname, host_id] or nil
      def host_id(connection)
        raise NotImplementedError
      end

      # Returns the SQL query used to retrieve the host alias.
      #
      # @return [String]
      def host_alias_query
        raise NotImplementedError
      end
    end
  end
end
