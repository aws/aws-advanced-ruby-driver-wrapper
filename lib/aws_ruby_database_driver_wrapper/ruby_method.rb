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

module AwsRubyDatabaseDriverWrapper
  # Represents a method that can be intercepted by the plugin pipeline.
  MethodInfo = Struct.new(:name, :check_bounded_connection, keyword_init: true) do
    def to_s
      name
    end
  end

  module RubyMethod
    def self.define(name, check_bounded_connection:)
      MethodInfo.new(name: name, check_bounded_connection: check_bounded_connection).freeze
    end

    # -- Internal pipeline methods --
    CONNECT = define('connect', check_bounded_connection: false)

    # -- Connection methods --
    CONNECTION_CLOSE               = define('connection.close', check_bounded_connection: false)
    CONNECTION_PING                = define('connection.ping', check_bounded_connection: false)
    CONNECTION_RESET               = define('connection.reset', check_bounded_connection: false)
    CONNECTION_PREPARE             = define('connection.prepare', check_bounded_connection: false)
    CONNECTION_ESCAPE              = define('connection.escape', check_bounded_connection: false)

    # -- Connection methods (mysql2-specific) --
    CONNECTION_QUERY               = define('connection.query', check_bounded_connection: false)
    CONNECTION_QUERY_ASYNC         = define('connection.query_async', check_bounded_connection: false)
    CONNECTION_SELECT_DB           = define('connection.select_db', check_bounded_connection: false)
    CONNECTION_MORE_RESULTS        = define('connection.more_results', check_bounded_connection: true)
    CONNECTION_NEXT_RESULT         = define('connection.next_result', check_bounded_connection: true)
    CONNECTION_STORE_RESULT        = define('connection.store_result', check_bounded_connection: true)
    CONNECTION_ABANDON_RESULTS     = define('connection.abandon_results!', check_bounded_connection: false)

    # -- Connection methods (pg-specific) --
    CONNECTION_EXEC                = define('connection.exec', check_bounded_connection: false)
    CONNECTION_ASYNC_EXEC          = define('connection.async_exec', check_bounded_connection: false)
    CONNECTION_EXEC_PARAMS         = define('connection.exec_params', check_bounded_connection: false)
    CONNECTION_EXEC_PREPARED       = define('connection.exec_prepared', check_bounded_connection: true)
    CONNECTION_DESCRIBE_PREPARED   = define('connection.describe_prepared', check_bounded_connection: true)
    CONNECTION_DESCRIBE_PORTAL     = define('connection.describe_portal', check_bounded_connection: false)
    CONNECTION_TRANSACTION         = define('connection.transaction', check_bounded_connection: false)
    CONNECTION_COPY_DATA           = define('connection.copy_data', check_bounded_connection: false)
    CONNECTION_PUT_COPY_DATA       = define('connection.put_copy_data', check_bounded_connection: true)
    CONNECTION_GET_COPY_DATA       = define('connection.get_copy_data', check_bounded_connection: true)
    CONNECTION_PUT_COPY_END        = define('connection.put_copy_end', check_bounded_connection: true)
    CONNECTION_SEND_QUERY          = define('connection.send_query', check_bounded_connection: false)
    CONNECTION_SEND_QUERY_PARAMS   = define('connection.send_query_params', check_bounded_connection: false)
    CONNECTION_SEND_QUERY_PREPARED = define('connection.send_query_prepared', check_bounded_connection: true)
    CONNECTION_SEND_PREPARE        = define('connection.send_prepare', check_bounded_connection: false)
    CONNECTION_GET_RESULT          = define('connection.get_result', check_bounded_connection: true)
    CONNECTION_GET_LAST_RESULT     = define('connection.get_last_result', check_bounded_connection: true)
    CONNECTION_CANCEL              = define('connection.cancel', check_bounded_connection: false)
    CONNECTION_SET_CLIENT_ENCODING = define('connection.set_client_encoding', check_bounded_connection: false)
    CONNECTION_WAIT_FOR_NOTIFY     = define('connection.wait_for_notify', check_bounded_connection: false)
    CONNECTION_NOTIFIES            = define('connection.notifies', check_bounded_connection: false)
    CONNECTION_CONSUME_INPUT       = define('connection.consume_input', check_bounded_connection: false)
    CONNECTION_FLUSH               = define('connection.flush', check_bounded_connection: false)
    CONNECTION_LO_OPEN             = define('connection.lo_open', check_bounded_connection: false)
    CONNECTION_LO_READ             = define('connection.lo_read', check_bounded_connection: true)
    CONNECTION_LO_WRITE            = define('connection.lo_write', check_bounded_connection: true)
    CONNECTION_LO_CLOSE            = define('connection.lo_close', check_bounded_connection: true)

    # -- Statement methods --
    STATEMENT_EXECUTE              = define('statement.execute', check_bounded_connection: true)
    STATEMENT_CLOSE                = define('statement.close', check_bounded_connection: false)

    # -- Result methods --
    RESULT_EACH                    = define('result.each', check_bounded_connection: true)
    RESULT_EACH_ROW                = define('result.each_row', check_bounded_connection: true)
    RESULT_TO_A                    = define('result.to_a', check_bounded_connection: true)
    RESULT_BRACKET                 = define('result.[]', check_bounded_connection: true)
    RESULT_VALUES                  = define('result.values', check_bounded_connection: true)
    RESULT_COLUMN_VALUES           = define('result.column_values', check_bounded_connection: true)
    RESULT_FIELD_VALUES            = define('result.field_values', check_bounded_connection: true)
    RESULT_TUPLE                   = define('result.tuple', check_bounded_connection: true)
  end
end
