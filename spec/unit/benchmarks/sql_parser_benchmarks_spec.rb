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

require_relative '../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/utils/parser/pg_statement_analyzer'
require 'aws_advanced_ruby_driver_wrapper/utils/parser/mysql_statement_analyzer'

# Guards the assumptions the SQL parser benchmark relies on: that both statement analyzers classify
# the benchmarked statements correctly. The benchmark is not run in CI, so drift in either analyzer
# fails here instead of the benchmark silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe 'SQL parser benchmark analyzers' do
    QT = Utils::Parser::QueryType

    shared_examples 'a statement analyzer' do |analyzer, select_sql, insert_sql|
      it 'classifies a SELECT and captures its table' do
        analysis = analyzer.analyze(select_sql)
        expect(analysis.query_type).to eq(QT::SELECT)
        expect(analysis.tables).to include('users')
      end

      it 'classifies an INSERT and captures its table' do
        analysis = analyzer.analyze(insert_sql)
        expect(analysis.query_type).to eq(QT::INSERT)
        expect(analysis.tables).to include('users')
      end

      it 'returns an unknown analysis for a blank statement' do
        expect(analyzer.analyze('').query_type).to eq(QT::UNKNOWN)
      end
    end

    context 'with the PostgreSQL analyzer' do
      include_examples 'a statement analyzer',
                       Utils::Parser::PgStatementAnalyzer,
                       'SELECT id, name FROM users WHERE id = $1',
                       'INSERT INTO users (id, name, email, ssn) VALUES ($1, $2, $3, $4)'
    end

    context 'with the MySQL analyzer' do
      include_examples 'a statement analyzer',
                       Utils::Parser::MysqlStatementAnalyzer,
                       'SELECT id, name FROM users WHERE id = ?',
                       'INSERT INTO users (id, name, email, ssn) VALUES (?, ?, ?, ?)'
    end
  end
end
