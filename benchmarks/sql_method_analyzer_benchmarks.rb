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

# Micro-benchmarks for Utils::SqlMethodAnalyzer, the statement inspection done on the hot path.
# SessionStateService consults it after every executed statement to keep autocommit and in-transaction
# state current, and the SQL-inspecting paths are not free: each one strips comments character by
# character, splits on ';', squeezes whitespace, then upper-cases the first statement.
#
# The cases are split by the shape of the input rather than by method, because the cost is driven
# almost entirely by whether the analyzer takes an early return or falls through to comment stripping
# and normalisation:
#   - non_sql_method - a call whose method carries no SQL, expected to short-circuit on a set lookup.
#   - simple_select  - a typical single statement, the full strip-and-normalise path.
#   - with_comments  - the same statement carrying line and block comments, which exercises the
#     character-by-character comment stripper.
#   - multi_statement - a batch, which additionally exercises the split on ';'.
#
# Read the cases against each other: the gap between simple_select and non_sql_method is the per-call
# tax paid by every statement execution, and with_comments over simple_select is the price of the
# comment stripper.
#
# The analyzer normalises SQL itself (comment stripping plus prefix matching) and is driver-agnostic,
# so there is nothing pg- or mysql-specific to choose here; mysql_backslash_escapes is left at its
# default of false, which is the behaviour used for the PostgreSQL driver.
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

# The false->true autocommit switch has no single method: SessionStateService derives it from
# sets_autocommit? and autocommit_value together, the same way it is reconstructed here.
def switches_autocommit_false_to_true?(method_name, args)
  ANALYZER.sets_autocommit?(method_name, args) && ANALYZER.autocommit_value(args) == true
end

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  # opens_transaction? - the check run after every executed statement (autocommit off).
  x.report('opens_transaction:non_sql_method') { ANALYZER.opens_transaction?(NON_SQL_METHOD, nil, autocommit: true) }
  x.report('opens_transaction:simple_select') { ANALYZER.opens_transaction?(EXECUTE_METHOD, SIMPLE_SELECT_ARGS, autocommit: false) }
  x.report('opens_transaction:with_comments') { ANALYZER.opens_transaction?(EXECUTE_METHOD, COMMENTED_SELECT_ARGS, autocommit: false) }
  x.report('opens_transaction:multi_statement') { ANALYZER.opens_transaction?(EXECUTE_METHOD, MULTI_STATEMENT_ARGS, autocommit: false) }

  # closes_transaction? - the matching check for COMMIT/ROLLBACK and close.
  x.report('closes_transaction:non_sql_method') { ANALYZER.closes_transaction?(NON_SQL_METHOD, nil) }
  x.report('closes_transaction:simple_select') { ANALYZER.closes_transaction?(EXECUTE_METHOD, SIMPLE_SELECT_ARGS) }
  x.report('closes_transaction:multi_statement') { ANALYZER.closes_transaction?(EXECUTE_METHOD, MULTI_STATEMENT_ARGS) }

  # The autocommit false->true switch, via SQL and on a plain select (the common early-false path).
  x.report('switch_autocommit_false_true:simple_select') { switches_autocommit_false_to_true?(EXECUTE_METHOD, SIMPLE_SELECT_ARGS) }
  x.report('switch_autocommit_false_true:via_sql') { switches_autocommit_false_to_true?(EXECUTE_METHOD, SET_AUTOCOMMIT_ARGS) }

  # The pieces the switch is built from, measured on their own.
  x.report('sets_autocommit:via_sql') { ANALYZER.sets_autocommit?(EXECUTE_METHOD, SET_AUTOCOMMIT_ARGS) }
  x.report('autocommit_value:via_sql') { ANALYZER.autocommit_value(SET_AUTOCOMMIT_ARGS) }

  # Pure set lookup on a closing method, the floor for the other measurements.
  x.report('method_close_lookup') { ANALYZER.closes_transaction?(CLOSE_METHOD, nil) }

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
    puts "#{entry.label.ljust(44)} #{ops.to_s.rjust(12)} ops/s  (+/-#{error}%)"
  end
end

puts "\nWrote #{path}"
