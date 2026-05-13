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
  module RubyMethod
    CONNECT                        = 'connect'

    # -- Connection methods (shared) --
    CONNECTION_CLOSE               = 'connection.close'
    CONNECTION_PING                = 'connection.ping'
    CONNECTION_RESET               = 'connection.reset'
    CONNECTION_PREPARE             = 'connection.prepare'
    CONNECTION_ESCAPE              = 'connection.escape'

    # -- Connection methods (mysql2-specific) --
    CONNECTION_QUERY               = 'connection.query'
    CONNECTION_QUERY_ASYNC         = 'connection.query_async'
    CONNECTION_SELECT_DB           = 'connection.select_db'
    CONNECTION_MORE_RESULTS        = 'connection.more_results'
    CONNECTION_NEXT_RESULT         = 'connection.next_result'
    CONNECTION_STORE_RESULT        = 'connection.store_result'
    CONNECTION_ABANDON_RESULTS     = 'connection.abandon_results!'

    # -- Connection methods (pg-specific) --
    CONNECTION_EXEC                = 'connection.exec'
    CONNECTION_ASYNC_EXEC          = 'connection.async_exec'
    CONNECTION_EXEC_PARAMS         = 'connection.exec_params'
    CONNECTION_EXEC_PREPARED       = 'connection.exec_prepared'
    CONNECTION_DESCRIBE_PREPARED   = 'connection.describe_prepared'
    CONNECTION_DESCRIBE_PORTAL     = 'connection.describe_portal'
    CONNECTION_TRANSACTION         = 'connection.transaction'
    CONNECTION_COPY_DATA           = 'connection.copy_data'
    CONNECTION_PUT_COPY_DATA       = 'connection.put_copy_data'
    CONNECTION_GET_COPY_DATA       = 'connection.get_copy_data'
    CONNECTION_PUT_COPY_END        = 'connection.put_copy_end'
    CONNECTION_SEND_QUERY          = 'connection.send_query'
    CONNECTION_SEND_QUERY_PARAMS   = 'connection.send_query_params'
    CONNECTION_SEND_QUERY_PREPARED = 'connection.send_query_prepared'
    CONNECTION_SEND_PREPARE        = 'connection.send_prepare'
    CONNECTION_GET_RESULT          = 'connection.get_result'
    CONNECTION_GET_LAST_RESULT     = 'connection.get_last_result'
    CONNECTION_CANCEL              = 'connection.cancel'
    CONNECTION_SET_CLIENT_ENCODING = 'connection.set_client_encoding'

    # -- Statement methods --
    STATEMENT_EXECUTE              = 'statement.execute'
    STATEMENT_CLOSE                = 'statement.close'

    # -- Result methods --
    RESULT_EACH                    = 'result.each'
  end
end
