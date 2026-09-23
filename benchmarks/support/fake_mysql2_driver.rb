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

require 'mysql2'

module AwsAdvancedRubyDriverWrapper
  module Benchmarks
    # A stand-in for a mysql2 connection that never touches a database. It returns canned results so a
    # wrapped call and a raw call can be measured against the identical target, making the difference
    # between them the wrapper's own overhead.
    module FakeMysql2Driver
      ROW = { 'id' => 42, 'name' => 'benchmark' }.freeze
      FIELDS = %w[id name].freeze

      # Reports itself as a Mysql2::Result so the wrapper's result-wrapping path runs, and yields a
      # fixed number of canned rows.
      class FakeResult
        include Enumerable

        def initialize(row_count)
          @rows = Array.new(row_count, ROW)
        end

        def is_a?(klass)
          klass == Mysql2::Result || super
        end

        def each(*_args, &block)
          return @rows.each unless block

          @rows.each(&block)
        end

        def to_a
          @rows
        end

        def fields
          FIELDS
        end
      end

      class FakeStatement
        def execute(*_params, **_options)
          FakeResult.new(1)
        end

        def close; end
      end

      # Responds to the methods the wrapper client forwards. +query+ returns a result sized by
      # +row_count+ so the per-row benchmarks can vary the row count against a fixed target.
      class FakeClient
        def initialize(row_count: 1)
          @row_count = row_count
        end

        def query(_sql, _options = {})
          FakeResult.new(@row_count)
        end

        def prepare(_sql)
          FakeStatement.new
        end

        def escape(string)
          string
        end

        # Named to match the mysql2 client method, not as a predicate.
        def ping # rubocop:disable Naming/PredicateMethod
          true
        end

        def close; end
      end
    end
  end
end
