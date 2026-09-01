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

require_relative '../../errors'

module AwsAdvancedRubyDriverWrapper
  module Plugins
    module Encryption
      # Gives the encryption components (KeyManager, MetadataManager, KeyManagementUtility) a
      # connection to run a statement on. It is supplied one of two ways, and exactly one must be set:
      #
      # * +connection+ - a caller-owned connection, reused for every operation and never closed here.
      #   This is how {KeyManagementUtility} wires things for a user with a connection in hand.
      # * +service_container+ - the plugin's runtime source: each call opens a short-lived connection
      #   of its own through the wrapper's connect pipeline and closes it afterward, so metadata and
      #   key reads never ride the application's connection.
      module ConnectionSource
        # Records the connection source from a constructor. Exactly one argument must be non-nil.
        #
        # @raise [ArgumentError] unless exactly one of the two is given
        def use_connection_source(connection:, service_container:)
          if [connection, service_container].compact.size != 1
            raise ArgumentError, 'provide exactly one of connection: or service_container:'
          end

          @connection = connection
          @service_container = service_container
        end

        # Yields a usable connection. A supplied connection is yielded as-is and left open; otherwise a
        # short-lived connection is opened for the call and closed afterward.
        #
        # @param operation [String, nil] operation name, for error context
        # @yieldparam connection [Object] a pg or mysql2 connection
        # @return [Object] whatever the block returns
        # @raise [Errors::AwsError] if a runtime connection cannot be opened
        def with_connection(operation: nil)
          return yield(@connection) if @connection

          connection = open_runtime_connection(operation)
          begin
            yield connection
          ensure
            close_runtime_connection(connection)
          end
        end

        private

        # Opens a short-lived connection through the connect pipeline, the way the plugin's runtime
        # reads its metadata and keys (independent of the application's connection).
        def open_runtime_connection(operation)
          connection_service = @service_container.connection_service
          connection = @service_container.plugin_manager.internal_connect(
            connection_service.current_host_info,
            connection_service.driver_props.dup,
            connection_service.wrapper_props,
            false
          )
          if connection.nil?
            raise AwsAdvancedRubyDriverWrapper::Errors::AwsError,
                  "The connect pipeline returned no connection for #{operation || 'a metadata query'}"
          end

          connection
        end

        def close_runtime_connection(connection)
          return if connection.nil?

          @service_container.dialect_service.driver_dialect.close_connection(connection)
        rescue StandardError
          nil
        end
      end
    end
  end
end
