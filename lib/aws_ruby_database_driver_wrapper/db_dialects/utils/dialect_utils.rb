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
#  limitations under the License.module DialectUtils
#
require_relative '../../host/host_role'

module AwsRubyDatabaseDriverWrapper
  module DbDialects
    module DialectUtils
      # Returns the hostname for the given connection.
      #
      # @param driver_dialect [Object] the driver dialect used to execute queries
      # @param connection [Object] the connection to analyze
      # @param host_id_query [String] the SQL query to retrieve the host ID
      # @return [String, nil] host_name or nil
      def query_instance_id(driver_dialect, connection, host_id_query)
        result = driver_dialect.execute(connection, host_id_query)
        return nil if result.nil? || result.empty?

        result.first.values[0]
      rescue StandardError
        nil
      end

      # Determines the role of the host behind the given connection.
      #
      # @param driver_dialect [Object] the driver dialect used to execute queries
      # @param connection [Object] the connection to analyze
      # @param reader_check_query [String] the SQL query to check if the host is a reader
      # @return [HostRole] :writer or :reader
      def query_host_role(driver_dialect, connection, reader_check_query)
        result = driver_dialect.execute(connection, reader_check_query)
        result[0][0] == 't' ? HostRole::READER : HostRole::WRITER
      end

      # Checks that all given queries return non-empty results.
      #
      # @param driver_dialect [Object] the driver dialect used to execute queries
      # @param connection [Object] the connection to execute queries against
      # @param queries [Array<String>] one or more SQL queries to verify
      # @return [Boolean] true if all queries return results, false otherwise
      def check_existence_queries(driver_dialect, connection, *queries)
        return false unless driver_dialect.respond_to?(:execute)

        queries.each do |existence_query|
          result = driver_dialect.execute(connection, existence_query)
          return false if result.nil? || result.empty?
        end
        true
      rescue StandardError
        false
      end
    end
  end
end
