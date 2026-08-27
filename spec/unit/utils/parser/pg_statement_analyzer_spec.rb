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

    it 'returns COPY for a COPY that stores rows' do
      expect(subject.analyze('COPY users (name, ssn) FROM STDIN').query_type).to eq(QueryType::COPY)
    end

    # A COPY that reads is no more a write than the SELECT it stands in for.
    it 'returns SELECT for a COPY that reads rows' do
      expect(subject.analyze('COPY users TO STDOUT').query_type).to eq(QueryType::SELECT)
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

    # The column can sit on either side of the operator; a parameter on the left maps just the same.
    it 'maps a WHERE column when the parameter is on the left of the operator' do
      expect(pg_parser.column_parameter_mapping('SELECT * FROM users WHERE $1 = name')).to eq({ 1 => 'name' })
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

  # A COPY's rows are a stream on the connection rather than bind parameters, so every column it
  # writes is one a caller cannot substitute a value for.
  describe 'a COPY' do
    it 'reports the table it writes and the columns it names, none of them substitutable' do
      result = subject.analyze('COPY users (name, ssn) FROM STDIN')

      expect(result.tables).to eq(['users'])
      expect(result.write_columns).to be_empty
      expect(result.unbound_write_columns.map { |c| [c.table_name, c.column_name] }).to eq([%w[users name], %w[users ssn]])
      expect(result.write_columns_complete).to be(true)
    end

    it 'reads the columns of a COPY however it is spelled' do
      ['COPY users (name, ssn) FROM STDIN WITH (FORMAT csv, HEADER)',
       "COPY users (name, ssn) FROM '/tmp/users.csv'",
       "COPY users (name, ssn) FROM PROGRAM 'cat /tmp/users.csv'",
       'copy users (name, ssn) from stdin'].each do |sql|
        result = subject.analyze(sql)

        expect(result.query_type).to eq(QueryType::COPY)
        expect(result.unbound_write_columns.map(&:column_name)).to eq(%w[name ssn]), "for #{sql}"
      end
    end

    # Without a column list the stream fills the table's columns in the order the table declares
    # them, which the statement does not carry.
    it 'reports a COPY that names no columns as not enumerable' do
      result = subject.analyze('COPY users FROM STDIN')

      expect(result.tables).to eq(['users'])
      expect(result.unbound_write_columns).to be_empty
      expect(result.write_columns_complete).to be(false)
    end

    it 'reports the table a COPY reads without treating it as a write' do
      result = subject.analyze('COPY users TO STDOUT')

      expect(result.query_type).to eq(QueryType::SELECT)
      expect(result.tables).to eq(['users'])
      expect(result.unbound_write_columns).to be_empty
    end

    # A COPY of a query reads whatever the query reads, which is what a caller has to know about.
    it 'reports the tables of the query a COPY reads' do
      result = subject.analyze('COPY (SELECT u.name FROM users u JOIN accounts a ON a.uid = u.id) TO STDOUT')

      expect(result.query_type).to eq(QueryType::SELECT)
      expect(result.tables).to include('users', 'accounts')
    end
  end

  # A PREPARE writes nothing itself, but the statement it carries is the one a later EXECUTE runs, and
  # the PREPARE is the only place its text appears.
  describe 'a PREPARE' do
    it 'reads the statement it carries as the statement it is' do
      result = subject.analyze('PREPARE ins AS INSERT INTO users (name, ssn) VALUES ($1, $2)')

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.tables).to eq(['users'])
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['name', 1], ['ssn', 2]])
      expect(result.write_columns_complete).to be(true)
      expect(result.parameterized).to be(true)
    end

    it 'reads it past the parameter types it declares' do
      result = subject.analyze('prepare ins (text, text) as insert into users (name, ssn) values ($1, $2)')

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.write_columns.map(&:column_name)).to eq(%w[name ssn])
    end

    # A value written into the body is a value no caller can substitute for, which is the whole reason
    # for reading the body at all.
    it 'reports a value written into the statement it carries as not substitutable' do
      result = subject.analyze("PREPARE ins AS INSERT INTO users (ssn) VALUES ('123-45-6789')")

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.write_columns).to be_empty
      expect(result.unbound_write_columns.map { |c| [c.table_name, c.column_name] }).to eq([%w[users ssn]])
    end

    it 'reports a PREPARE that carries a read as a read' do
      result = subject.analyze('PREPARE q AS SELECT ssn FROM users WHERE id = $1')

      expect(result.query_type).to eq(QueryType::SELECT)
      expect(result.tables).to eq(['users'])
      expect(result.where_columns.map(&:column_name)).to eq(['id'])
    end

    it 'reports a PREPARE whose body says nothing about what it writes as unknown' do
      result = subject.analyze('PREPARE d AS DEALLOCATE ALL')

      expect(result.query_type).to eq(QueryType::UNKNOWN)
      expect(result.write_columns_complete).to be(false)
    end

    it 'collects the table of a PREPARE sent alongside another statement' do
      result = subject.analyze("PREPARE ins AS INSERT INTO users (ssn) VALUES ($1); INSERT INTO logs (note) VALUES ('x')")

      expect(result.tables).to include('users', 'logs')
      expect(result.write_columns_complete).to be(false)
    end
  end

  # A MERGE writes through its WHEN clauses, so it is reported as a write rather than being refused
  # wholesale, and its bound values are paired with the columns they fill.
  describe 'a MERGE' do
    it 'reads the columns its UPDATE and INSERT clauses write and the parameters that fill them' do
      result = subject.analyze(
        'MERGE INTO accounts USING txns ON accounts.id = txns.acct ' \
        'WHEN MATCHED THEN UPDATE SET ssn = $1 ' \
        'WHEN NOT MATCHED THEN INSERT (id, ssn) VALUES ($2, $3)'
      )

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.tables).to eq(['accounts'])
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['ssn', 1], ['id', 2], ['ssn', 3]])
      expect(result.write_columns_complete).to be(true)
    end

    it 'reports a value written by an expression as one it cannot substitute' do
      result = subject.analyze(
        'MERGE INTO accounts USING txns ON accounts.id = txns.acct ' \
        'WHEN MATCHED THEN UPDATE SET ssn = upper($1)'
      )

      expect(result.write_columns).to be_empty
      expect(result.unbound_write_columns.map(&:column_name)).to eq(['ssn'])
    end

    # An INSERT clause with no column list fills the table's columns in its own order, which the
    # statement does not carry, so the write cannot be enumerated and must fail closed.
    it 'reports an INSERT clause with no column list as not enumerable' do
      result = subject.analyze(
        'MERGE INTO accounts USING txns ON accounts.id = txns.acct ' \
        'WHEN NOT MATCHED THEN INSERT VALUES ($1, $2)'
      )

      expect(result.tables).to eq(['accounts'])
      expect(result.write_columns).to be_empty
      expect(result.write_columns_complete).to be(false)
    end

    # A clause that only deletes stores nothing, so there is nothing to enumerate and nothing to fail
    # closed over.
    it 'treats a MERGE whose only action deletes as enumerable with no written columns' do
      result = subject.analyze(
        'MERGE INTO accounts USING txns ON accounts.id = txns.acct WHEN MATCHED THEN DELETE'
      )

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.write_columns).to be_empty
      expect(result.write_columns_complete).to be(true)
    end
  end

  # A data-modifying CTE writes through the statement that carries it, even when the top-level
  # statement is a SELECT, so it must be seen as a write rather than mistaken for a read.
  describe 'a data-modifying CTE' do
    it 'reports the write of an INSERT CTE under a SELECT, with its parameter mapped' do
      result = subject.analyze(
        'WITH w AS (INSERT INTO users (ssn) VALUES ($1) RETURNING id) SELECT * FROM w'
      )

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.tables).to eq(['users'])
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['ssn', 1]])
      expect(result.write_columns_complete).to be(true)
    end

    it 'reports an UPDATE CTE under a SELECT as a write' do
      result = subject.analyze(
        'WITH w AS (UPDATE users SET ssn = $1 WHERE id = $2 RETURNING id) SELECT * FROM w'
      )

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.tables).to eq(['users'])
      expect(result.write_columns.map(&:column_name)).to eq(['ssn'])
    end

    # A CTE the analyzer cannot read column-by-column must fail closed, not be taken for a read.
    it 'reports a CTE INSERT ... SELECT as not enumerable' do
      result = subject.analyze(
        'WITH w AS (INSERT INTO users (ssn) SELECT secret FROM staging RETURNING id) SELECT * FROM w'
      )

      expect(result.query_type).to eq(QueryType::INSERT)
      expect(result.tables).to eq(['users'])
      expect(result.write_columns_complete).to be(false)
    end

    # A CTE that only reads leaves the statement a plain SELECT.
    it 'leaves a read-only CTE as a SELECT' do
      result = subject.analyze('WITH w AS (SELECT id FROM users) SELECT * FROM w')

      expect(result.query_type).to eq(QueryType::SELECT)
    end
  end
end
