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

# Micro-benchmarks for Utils::SqlMethodAnalyzer.transaction_effect, the statement inspection done on
# the hot path. SessionStateService consults it after every executed statement to keep autocommit and
# in-transaction state current, and the SQL-inspecting path is not free: it strips comments character
# by character, splits on ';', squeezes whitespace, then upper-cases the first statement.
#
# The cases are split by the shape of the input, because the cost is driven almost entirely by
# whether the analyzer takes an early return or falls through to comment stripping and normalisation:
#   - non_sql_method - a call whose method carries no SQL, expected to short-circuit on a set lookup.
#   - close_method   - a close/transaction method, also a set lookup with no SQL (the floor).
#   - simple_select  - a typical single statement, the full strip-and-normalise path.
#   - with_comments  - the same statement carrying line and block comments, which exercises the
#     character-by-character comment stripper.
#   - multi_statement - a batch, which additionally exercises the split on ';'.
#   - set_autocommit - a SET AUTOCOMMIT statement, which additionally parses the autocommit value.
#
# Read the cases against each other: the gap between simple_select and non_sql_method is the per-call
# tax paid by every statement execution, and with_comments over simple_select is the price of the
# comment stripper.
#
# The analyzer normalises SQL itself and is driver-agnostic, so there is nothing pg- or mysql-specific
# to choose here; mysql_backslash_escapes is left at its default of false.
#
# Results are reported in iterations per second (higher is better) and written to
# benchmarks/results/sql_method_analyzer.csv.
#
# Run with: bundle exec ruby benchmarks/sql_method_analyzer_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/utils/sql_method_analyzer'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

ANALYZER = Utils::SqlMethodAnalyzer

SIMPLE_SELECT = 'SELECT id, name FROM users WHERE id = 42'
COMMENTED_SELECT =
  "-- pick a user\n/* by primary key */ SELECT id, name FROM users WHERE id = 42 -- trailing"
MULTI_STATEMENT =
  "BEGIN; UPDATE users SET name = 'a' WHERE id = 1; UPDATE users SET name = 'b' WHERE id = 2; COMMIT"
SET_AUTOCOMMIT = 'SET AUTOCOMMIT = 1'

EXECUTE_METHOD = RubyMethod::STATEMENT_EXECUTE.name
NON_SQL_METHOD = RubyMethod::CONNECTION_PING.name
CLOSE_METHOD = RubyMethod::CONNECTION_CLOSE.name

SIMPLE_SELECT_ARGS = [SIMPLE_SELECT].freeze
COMMENTED_SELECT_ARGS = [COMMENTED_SELECT].freeze
MULTI_STATEMENT_ARGS = [MULTI_STATEMENT].freeze
SET_AUTOCOMMIT_ARGS = [SET_AUTOCOMMIT].freeze

RESULTS_DIR = File.expand_path('results', __dir__)

# The autocommit-off cases take the fuller path (transaction-scope check plus autocommit handling),
# which is what a statement executed inside a transaction pays.
def effect(method_name, args)
  ANALYZER.transaction_effect(method_name, args, autocommit: false, autocommit_before: false)
end

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  x.report('transaction_effect:non_sql_method') { effect(NON_SQL_METHOD, nil) }
  x.report('transaction_effect:close_method') { effect(CLOSE_METHOD, nil) }
  x.report('transaction_effect:simple_select') { effect(EXECUTE_METHOD, SIMPLE_SELECT_ARGS) }
  x.report('transaction_effect:with_comments') { effect(EXECUTE_METHOD, COMMENTED_SELECT_ARGS) }
  x.report('transaction_effect:multi_statement') { effect(EXECUTE_METHOD, MULTI_STATEMENT_ARGS) }
  x.report('transaction_effect:set_autocommit') { effect(EXECUTE_METHOD, SET_AUTOCOMMIT_ARGS) }

  x.compare!
end

# -- Export one CSV for charting --

FileUtils.mkdir_p(RESULTS_DIR)

path = File.join(RESULTS_DIR, 'sql_method_analyzer.csv')
puts "\nOps/Second by case:\n\n"
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  report.entries.each do |entry|
    ops = entry.stats.central_tendency.round
    error = entry.stats.error_percentage.round(2)
    csv << [entry.label, ops, error]
    puts "#{entry.label.ljust(40)} #{ops.to_s.rjust(12)} ops/s  (+/-#{error}%)"
  end
end

puts "\nWrote #{path}"
