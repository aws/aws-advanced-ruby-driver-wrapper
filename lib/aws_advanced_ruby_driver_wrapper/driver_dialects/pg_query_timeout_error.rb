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

# Loaded on demand (see PgDriverDialect#await_result): it inherits from PG::ConnectionBad, which needs the pg gem.
require 'pg'

module AwsAdvancedRubyDriverWrapper
  module DriverDialects
    class PgDriverDialect
      # Raised when a wrapper-internal query gets no reply within its timeout (see #with_query_timeout).
      #
      # It is a +PG::ConnectionBad+, so callers that rescue the driver's connection error handle it, and
      # PgErrorHandler#network_error? recognizes it by class. The trailing newline is deliberate: ActiveRecord
      # tells a libpq failure (message ends in a newline, the query may have reached the server) from a
      # pg-internal one (no newline, never sent) and maps the former to ActiveRecord::ConnectionFailed, which
      # is right for a query that was sent. Keep it, and avoid the phrases "connection is closed" and "no
      # connection to the server", which ActiveRecord matches first.
      class QueryTimeoutError < ::PG::ConnectionBad
        def initialize(timeout_sec)
          super("wrapper internal query timed out after #{timeout_sec}s\n")
        end
      end
    end
  end
end
