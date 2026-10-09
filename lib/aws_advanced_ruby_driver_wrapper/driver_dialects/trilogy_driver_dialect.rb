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

require_relative 'mysql_driver_dialect'

module AwsAdvancedRubyDriverWrapper
  module DriverDialects
    # The trilogy driver speaks the same MySQL protocol and grammar as mysql2, so everything that
    # depends only on the server is inherited. What is overridden is how the driver itself is called.
    class TrilogyDriverDialect < MysqlDriverDialect
      # The trilogy calls that talk to the server and that failover should cover. The failover, Blue/Green
      # and Custom Endpoint plugins subscribe to exactly these, and a call that is not listed here and
      # reaches the client's method_missing is handed straight to the driver.
      #
      # Not listed, because trilogy answers them without talking to the server: escape, closed?,
      # more_results_exist?, the counts and ids of the last statement, server_status, in_transaction?,
      # server_version, the query flags and timeouts, and discard!, which only lets go of the socket.
      # A Trilogy::Result is read off the wire in full before it is returned, so reading its rows
      # never talks to the server either.
      #
      # Not listed although it talks to the server: ping, as for mysql2. ActiveRecord pings to check
      # that a connection is still alive and rescues the driver's own errors to answer false and
      # reconnect; failing over inside that check would raise a wrapper error out of it instead.
      NETWORK_BOUND_METHODS = (COMMON_NETWORK_BOUND_METHODS | Set[
        RubyMethod::CONNECTION_QUERY.name,
        RubyMethod::CONNECTION_CHANGE_DB.name,
        RubyMethod::CONNECTION_NEXT_RESULT.name,
        RubyMethod::CONNECTION_ABANDON_RESULTS.name,
        RubyMethod::CONNECTION_SET_SERVER_OPTION.name
      ]).freeze

      # Trilogy.new stores the options it is given and writes to them, so it is handed a hash of its
      # own, which prepare_connect_config builds afresh on every call.
      def connect(host_info, config)
        ::Trilogy.new(prepare_connect_config(host_info, config))
      end

      # Trilogy returns rows as arrays. They are keyed by column name here, as mysql2 returns them,
      # because that is the shape the database dialects read their rows in.
      def execute(connection, sql)
        connection.query(sql).each_hash.to_a
      end

      # Trilogy has no prepared statements, so each parameter is written into the SQL as a literal,
      # quoted and escaped by the connection the way ActiveRecord quotes its own binds for trilogy.
      # Only the types the wrapper binds in its own queries are accepted.
      def execute_with_params(connection, sql, params)
        placeholders = sql.count('?')
        raise ArgumentError, "SQL has #{placeholders} placeholders for #{params.size} parameters" unless placeholders == params.size

        literals = params.map { |value| literal(connection, value) }
        bound_sql = sql.gsub('?') { literals.shift }

        execute(connection, bound_sql)
      end

      # Every reply from the server carries its status flags, and trilogy keeps the last of them, so
      # whether a transaction is open is known without inferring it from the SQL.
      def reported_in_transaction(connection)
        return nil if closed?(connection)

        connection.in_transaction?
      end

      # discard! closes the socket without sending COM_QUIT or a TLS close notify, leaving the
      # parent's session open.
      def abandon_connection(connection)
        return if connection.nil? || connection.closed?

        connection.discard!
      rescue StandardError => e
        logger.debug("Failed to abandon MySQL connection: #{e.message}")
      end

      def network_bound_methods
        NETWORK_BOUND_METHODS
      end

      private

      def literal(connection, value)
        case value
        when nil then 'NULL'
        when Integer then value.to_s
        when String then "'#{connection.escape(value)}'"
        else raise ArgumentError, "Cannot bind a #{value.class} parameter for trilogy"
        end
      end
    end
  end
end
