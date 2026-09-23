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

# Measures the column/table SQL analysis used to decide which parameters map to encrypted columns.
# Two very different implementations back it: PostgreSQL parses an AST through the pg_query C
# extension, while MySQL uses a regex-based analyzer. This runs once per statement whenever the
# encryption plugin is active, so it is the dominant cost of that plugin.
#
# The two series use driver-native parameter placeholders ($1 for PostgreSQL, ? for MySQL), so the
# absolute PostgreSQL-versus-MySQL comparison is directional rather than exact; read each series as
# the per-statement analysis cost for that driver.
#
# Run with: bundle exec ruby benchmarks/sql_parser_benchmarks.rb

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'benchmark/ips'
require 'csv'
require 'fileutils'
require 'aws_advanced_ruby_driver_wrapper'
require 'aws_advanced_ruby_driver_wrapper/utils/parser/pg_statement_analyzer'
require 'aws_advanced_ruby_driver_wrapper/utils/parser/mysql_statement_analyzer'

include AwsAdvancedRubyDriverWrapper # rubocop:disable Style/MixinUsage

RESULTS_DIR = File.expand_path('results', __dir__)

PG_QUERIES = {
  'simple_select' => 'SELECT id, name FROM users WHERE id = $1',
  'insert_columns' => 'INSERT INTO users (id, name, email, ssn) VALUES ($1, $2, $3, $4)',
  'join' => 'SELECT u.id, o.total FROM users u JOIN orders o ON o.user_id = u.id WHERE u.active = $1',
  'with_comments' => '/* app: web */ SELECT id FROM users WHERE id = $1'
}.freeze

MYSQL_QUERIES = {
  'simple_select' => 'SELECT id, name FROM users WHERE id = ?',
  'insert_columns' => 'INSERT INTO users (id, name, email, ssn) VALUES (?, ?, ?, ?)',
  'join' => 'SELECT u.id, o.total FROM users u JOIN orders o ON o.user_id = u.id WHERE u.active = ?',
  'with_comments' => '/* app: web */ SELECT id FROM users WHERE id = ?'
}.freeze

pg = Utils::Parser::PgStatementAnalyzer
mysql = Utils::Parser::MysqlStatementAnalyzer

report = Benchmark.ips do |x|
  x.config(warmup: 3, time: 5)

  PG_QUERIES.each { |name, sql| x.report("pg:#{name}") { pg.analyze(sql) } }
  MYSQL_QUERIES.each { |name, sql| x.report("mysql:#{name}") { mysql.analyze(sql) } }

  x.compare!
end

FileUtils.mkdir_p(RESULTS_DIR)

path = File.join(RESULTS_DIR, 'sql_parser.csv')
CSV.open(path, 'w') do |csv|
  csv << %w[name ops_per_second error_percent]
  report.entries.each do |entry|
    csv << [entry.label, entry.stats.central_tendency.round, entry.stats.error_percentage.round(2)]
  end
end

puts "\nWrote #{path}"
