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

require_relative '../../../spec_helper'
require 'aws_ruby_database_driver_wrapper/utils/parser/pg_statement_analyzer'
require 'aws_ruby_database_driver_wrapper/utils/parser/query_type'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::Parser::PgStatementAnalyzer do
  QueryType = AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType

  before { require 'pg_query' }

  subject { described_class }

  describe '.analyze query_type' do
    it 'returns SELECT' do
      expect(subject.analyze('SELECT * FROM users WHERE id = $1').query_type).to eq(QueryType::SELECT)
    end

    it 'returns INSERT' do
      expect(subject.analyze('INSERT INTO users (name, email) VALUES ($1, $2)').query_type).to eq(QueryType::INSERT)
    end

    it 'returns UPDATE' do
      expect(subject.analyze('UPDATE users SET name = $1 WHERE id = $2').query_type).to eq(QueryType::UPDATE)
    end

    it 'returns DELETE' do
      expect(subject.analyze('DELETE FROM users WHERE id = $1').query_type).to eq(QueryType::DELETE)
    end

    it 'returns CREATE' do
      expect(subject.analyze('CREATE TABLE t (id SERIAL PRIMARY KEY)').query_type).to eq(QueryType::CREATE)
    end

    it 'returns DROP' do
      expect(subject.analyze('DROP TABLE t').query_type).to eq(QueryType::DROP)
    end

    it 'returns UNKNOWN for nil' do
      expect(subject.analyze(nil).query_type).to eq(QueryType::UNKNOWN)
    end

    it 'returns UNKNOWN for empty string' do
      expect(subject.analyze('').query_type).to eq(QueryType::UNKNOWN)
    end
  end

  describe '.analyze tables' do
    it 'extracts table from SELECT' do
      expect(subject.analyze('SELECT * FROM users WHERE id = $1').tables).to include('users')
    end

    it 'extracts table from INSERT' do
      expect(subject.analyze('INSERT INTO users (name) VALUES ($1)').tables).to include('users')
    end

    it 'extracts table from UPDATE' do
      expect(subject.analyze('UPDATE users SET name = $1 WHERE id = $2').tables).to include('users')
    end

    it 'extracts table from DELETE' do
      expect(subject.analyze('DELETE FROM users WHERE id = $1').tables).to include('users')
    end

    it 'extracts both tables from JOIN' do
      result = subject.analyze('SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id')
      expect(result.tables).to include('users', 'orders')
    end
  end

  describe '.analyze column_parameter_mapping (via SqlParser)' do
    let(:pg_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new }
    subject(:pg_parser) { AwsRubyDatabaseDriverWrapper::Utils::Parser::SqlParser.new(pg_dialect) }

    before do
      require 'aws_ruby_database_driver_wrapper/utils/parser/sql_parser'
      require 'aws_ruby_database_driver_wrapper/driver_dialects/pg_driver_dialect'
    end
    it 'maps INSERT columns in order' do
      expect(pg_parser.column_parameter_mapping('INSERT INTO users (name, email) VALUES ($1, $2)')).to eq({ 1 => 'name', 2 => 'email' })
    end

    it 'maps SET columns only for UPDATE, not WHERE' do
      expect(pg_parser.column_parameter_mapping('UPDATE users SET name = $1, email = $2 WHERE id = $3')).to eq({ 1 => 'name',
                                                                                                                 2 => 'email' })
    end

    it 'maps WHERE columns for SELECT' do
      expect(pg_parser.column_parameter_mapping('SELECT * FROM users WHERE name = $1')).to eq({ 1 => 'name' })
    end

    it 'maps WHERE IN list params positionally' do
      expect(pg_parser.column_parameter_mapping('SELECT * FROM users WHERE name IN ($1, $2)')).to eq({ 1 => 'name', 2 => 'name' })
    end

    it 'maps BETWEEN as two entries for the same column' do
      expect(pg_parser.column_parameter_mapping('SELECT * FROM users WHERE age BETWEEN $1 AND $2')).to eq({ 1 => 'age', 2 => 'age' })
    end

    it 'maps ANY param' do
      expect(pg_parser.column_parameter_mapping('SELECT * FROM users WHERE id = ANY($1)')).to eq({ 1 => 'id' })
    end

    it 'returns empty for DELETE' do
      expect(pg_parser.column_parameter_mapping('DELETE FROM users WHERE id = $1')).to eq({})
    end
  end

  describe '.analyze parameterized' do
    it 'returns true when SQL contains $1-style parameters' do
      expect(subject.analyze('SELECT * FROM users WHERE id = $1').parameterized).to be true
    end

    it 'returns true when SQL contains multiple positional parameters' do
      expect(subject.analyze('SELECT * FROM users WHERE name = $1 AND age = $2').parameterized).to be true
    end

    it 'returns false when SQL has no parameters' do
      expect(subject.analyze('SELECT * FROM users').parameterized).to be false
    end

    it 'returns false when $ appears only inside a string literal' do
      expect(subject.analyze("SELECT * FROM notes WHERE body = 'Suzy paid $5'").parameterized).to be false
    end

    it 'returns false when $ appears in a string literal in an INSERT' do
      expect(subject.analyze("INSERT INTO notes (body) VALUES ('Price is $10')").parameterized).to be false
    end

    it 'returns false when $ appears in a string literal in an UPDATE' do
      expect(subject.analyze("UPDATE notes SET body = 'Cost: $20' WHERE id = 1").parameterized).to be false
    end

    it 'returns true when a real $1 param coexists with a $ in a string literal' do
      expect(subject.analyze("SELECT * FROM notes WHERE id = $1 AND body != 'free $'").parameterized).to be true
    end
  end

  describe '.analyze where_columns' do
    it 'extracts column from a plain equality' do
      result = subject.analyze('SELECT * FROM t WHERE id = $1')
      expect(result.where_columns.map(&:column_name)).to eq(['id'])
    end

    it 'extracts column from IN list — one entry per param' do
      result = subject.analyze('SELECT * FROM t WHERE name IN ($1, $2)')
      expect(result.where_columns.map(&:column_name)).to eq(%w[name name])
    end

    it 'extracts column from BETWEEN — two entries for the same column' do
      result = subject.analyze('SELECT * FROM t WHERE age BETWEEN $1 AND $2')
      expect(result.where_columns.map(&:column_name)).to eq(%w[age age])
    end

    it 'extracts column from ANY' do
      result = subject.analyze('SELECT * FROM t WHERE id = ANY($1)')
      expect(result.where_columns.map(&:column_name)).to eq(['id'])
    end

    it 'preserves positional order across mixed operators' do
      result = subject.analyze('SELECT * FROM t WHERE id = ANY($1) AND age BETWEEN $2 AND $3 AND name IN ($4, $5)')
      expect(result.where_columns.map(&:column_name)).to eq(%w[id age age name name])
    end

    it 'does not emit entries for subquery params — they are not outer positional params' do
      result = subject.analyze('SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE x = $1)')
      expect(result.where_columns).to be_empty
    end
  end

  # A caller that substitutes a parameter has to know which parameter fills which column, and has to
  # know when a column is filled by something it cannot substitute at all.
  describe 'write columns' do
    it 'pairs a column with the parameter that fills it, not with its position' do
      result = subject.analyze("INSERT INTO t (a, b, c) VALUES ($1, 'literal', $2)")

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['a', 1], ['c', 2]])
      expect(result.unbound_write_columns.map(&:column_name)).to eq(['b'])
      expect(result.write_columns_complete).to be(true)
    end

    it 'follows explicit parameter numbers rather than the order the columns are declared in' do
      result = subject.analyze('INSERT INTO t (a, b) VALUES ($2, $1)')

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['a', 2], ['b', 1]])
    end

    it 'reports every row of a multi-row INSERT' do
      result = subject.analyze('INSERT INTO t (a, b) VALUES ($1, $2), ($3, $4)')

      expect(result.write_columns.map(&:parameter_index)).to eq([1, 2, 3, 4])
      expect(result.write_columns.map(&:column_name)).to eq(%w[a b a b])
    end

    it 'reports the assignments of an upsert as well as its values' do
      result = subject.analyze('INSERT INTO t (a, b) VALUES ($1, $2) ON CONFLICT (a) DO UPDATE SET b = $3')

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] })
        .to eq([['a', 1], ['b', 2], ['b', 3]])
    end

    it 'treats a DEFAULT as a value it cannot substitute' do
      result = subject.analyze('INSERT INTO t (a, b) VALUES ($1, DEFAULT)')

      expect(result.unbound_write_columns.map(&:column_name)).to eq(['b'])
    end

    # A NULL is left out: there is nothing to encrypt in one, and a column set to NULL reads back as
    # NULL whether the plugin saw it or not.
    it 'passes over a column set to NULL' do
      result = subject.analyze('INSERT INTO t (a, b) VALUES ($1, NULL)')

      expect(result.unbound_write_columns).to be_empty
      expect(result.write_columns_complete).to be(true)
    end

    it 'reports an INSERT with no column list as not enumerable' do
      result = subject.analyze('INSERT INTO t VALUES ($1, $2)')

      expect(result.write_columns).to be_empty
      expect(result.write_columns_complete).to be(false)
      expect(result.tables).to eq(['t'])
    end

    it 'reports an INSERT from a SELECT as not enumerable' do
      result = subject.analyze('INSERT INTO t (a, b) SELECT x, y FROM u')

      expect(result.write_columns).to be_empty
      expect(result.write_columns_complete).to be(false)
    end

    it 'reports an expression around a parameter as a value it cannot substitute' do
      result = subject.analyze('UPDATE t SET a = upper($1) WHERE id = $2')

      expect(result.write_columns).to be_empty
      expect(result.unbound_write_columns.map(&:column_name)).to eq(['a'])
    end

    it 'reports SQL it cannot parse as not enumerable' do
      result = subject.analyze('INSERT INTO ((( $1')

      expect(result.write_columns_complete).to be(false)
    end

    # Only the first statement of a multi-statement string is analyzed, so what the rest write is
    # unknown, and their tables have to be reported for a caller to decide anything about them.
    it 'collects the tables of a multi-statement string and reports it as not enumerable' do
      result = subject.analyze('INSERT INTO t (a) VALUES ($1); INSERT INTO u (b) VALUES ($2)')

      expect(result.tables).to include('t', 'u')
      expect(result.write_columns_complete).to be(false)
    end
  end
end
