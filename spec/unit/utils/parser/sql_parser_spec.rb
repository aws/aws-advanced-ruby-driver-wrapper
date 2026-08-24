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
require 'aws_ruby_database_driver_wrapper/utils/parser/sql_parser'
require 'aws_ruby_database_driver_wrapper/utils/parser/query_type'
require 'aws_ruby_database_driver_wrapper/driver_dialects/mysql_driver_dialect'
require 'aws_ruby_database_driver_wrapper/driver_dialects/pg_driver_dialect'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::Parser::SqlParser do
  let(:mysql_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  let(:pg_dialect)    { AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new }
  subject(:mysql_parser) { described_class.new(mysql_dialect) }

  describe '#analyze_sql query_type' do
    it 'returns INSERT for a simple INSERT' do
      expect(mysql_parser.analyze_sql('INSERT INTO customers (name, email) VALUES (?, ?)').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::INSERT)
    end

    it 'returns UPDATE for a simple UPDATE' do
      expect(mysql_parser.analyze_sql('UPDATE customers SET email = ? WHERE id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UPDATE)
    end

    it 'returns SELECT for a simple SELECT' do
      expect(mysql_parser.analyze_sql('SELECT * FROM customers WHERE id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
    end

    it 'returns DELETE for a simple DELETE' do
      expect(mysql_parser.analyze_sql('DELETE FROM customers WHERE id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::DELETE)
    end

    it 'returns CREATE for CREATE TABLE' do
      expect(mysql_parser.analyze_sql('CREATE TABLE new_table (id SERIAL PRIMARY KEY, name VARCHAR(100))').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::CREATE)
    end

    it 'returns DROP for DROP TABLE' do
      expect(mysql_parser.analyze_sql('DROP TABLE old_table').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::DROP)
    end

    it 'is case-insensitive' do
      expect(mysql_parser.analyze_sql('insert into customers (name) values (?)').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::INSERT)
      expect(mysql_parser.analyze_sql('Update Customers Set Name = ? Where Id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UPDATE)
    end

    it 'returns UNKNOWN for empty string' do
      expect(mysql_parser.analyze_sql('').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end

    it 'returns UNKNOWN for nil' do
      expect(mysql_parser.analyze_sql(nil).query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end

    it 'returns UNKNOWN for whitespace only' do
      expect(mysql_parser.analyze_sql("   \n\t  ").query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end
  end

  describe '#analyze_sql affected_tables' do
    it 'returns the table for a simple INSERT' do
      expect(mysql_parser.analyze_sql('INSERT INTO customers (name, email) VALUES (?, ?)').affected_tables).to include('customers')
    end

    it 'strips schema prefix from table name' do
      expect(mysql_parser.analyze_sql("INSERT INTO public.users (id, username) VALUES (1, 'john')").affected_tables).to include('users')
    end

    it 'returns the table for a simple UPDATE' do
      expect(mysql_parser.analyze_sql('UPDATE customers SET email = ? WHERE id = ?').affected_tables).to include('customers')
    end

    it 'strips schema prefix on UPDATE' do
      sql = 'UPDATE public.inventory SET quantity = quantity - 1 WHERE product_id = ?'
      expect(mysql_parser.analyze_sql(sql).affected_tables).to include('inventory')
    end

    it 'returns the table for a simple SELECT' do
      expect(mysql_parser.analyze_sql('SELECT * FROM customers WHERE id = ?').affected_tables).to include('customers')
    end

    it 'includes both tables for SELECT with JOIN' do
      result = mysql_parser.analyze_sql('SELECT c.name, o.total FROM customers c JOIN orders o ON c.id = o.customer_id')
      expect(result.affected_tables).to include('customers', 'orders')
    end

    it 'returns the table for DELETE' do
      expect(mysql_parser.analyze_sql('DELETE FROM customers WHERE id = ?').affected_tables).to include('customers')
    end

    it 'includes the target table for INSERT...SELECT' do
      result = mysql_parser.analyze_sql('INSERT INTO backup_customers SELECT * FROM customers WHERE active = true')
      expect(result.affected_tables).to include('backup_customers')
    end

    it 'returns an empty set for empty sql' do
      expect(mysql_parser.analyze_sql('').affected_tables).to be_empty
    end

    it 'returns an empty set for nil' do
      expect(mysql_parser.analyze_sql(nil).affected_tables).to be_empty
    end
  end

  describe '#column_parameter_mapping' do
    it 'maps SET columns only for UPDATE' do
      expect(mysql_parser.column_parameter_mapping('UPDATE users SET ssn = ?, email = ? WHERE id = ?')).to eq({ 1 => 'ssn', 2 => 'email' })
    end

    it 'maps a single SET column for UPDATE' do
      expect(mysql_parser.column_parameter_mapping('UPDATE customers SET name = ? WHERE id = ?')).to eq({ 1 => 'name' })
    end

    it 'maps multiple SET columns for UPDATE' do
      sql = 'UPDATE products SET name = ?, price = ?, description = ? WHERE category = ?'
      expect(mysql_parser.column_parameter_mapping(sql)).to eq({ 1 => 'name', 2 => 'price', 3 => 'description' })
    end

    it 'maps SET columns even when WHERE uses a literal' do
      sql = 'UPDATE customers SET name = ?, ssn = ? WHERE id = 123'
      expect(mysql_parser.column_parameter_mapping(sql)).to eq({ 1 => 'name', 2 => 'ssn' })
    end

    it 'maps WHERE columns only for SELECT' do
      expect(mysql_parser.column_parameter_mapping('SELECT ssn FROM users WHERE name = ?')).to eq({ 1 => 'name' })
    end

    it 'maps multiple WHERE columns for SELECT' do
      sql = 'SELECT ssn, email FROM users WHERE name = ? AND age = ?'
      expect(mysql_parser.column_parameter_mapping(sql)).to eq({ 1 => 'name', 2 => 'age' })
    end

    it 'returns empty for SELECT with no ?' do
      expect(mysql_parser.column_parameter_mapping("SELECT ssn FROM users WHERE name = 'John'")).to eq({})
    end

    it 'maps the column list for INSERT' do
      sql = 'INSERT INTO customers (name, ssn, credit_card, email) VALUES (?, ?, ?, ?)'
      expected = { 1 => 'name', 2 => 'ssn', 3 => 'credit_card', 4 => 'email' }
      expect(mysql_parser.column_parameter_mapping(sql)).to eq(expected)
    end

    it 'returns empty for DELETE' do
      expect(mysql_parser.column_parameter_mapping('DELETE FROM users WHERE id = ?')).to eq({})
    end

    it 'returns empty for nil' do
      expect(mysql_parser.column_parameter_mapping(nil)).to eq({})
    end

    it 'returns empty for empty string' do
      expect(mysql_parser.column_parameter_mapping('')).to eq({})
    end
  end

  context 'with PostgreSQL dialect' do
    subject(:pg_parser) { described_class.new(pg_dialect) }

    def pg_stmt(hash)
      stmt      = double('stmt', to_h: hash)
      stmt_wrap = double('stmt_wrap', stmt: stmt)
      tree      = double('tree', stmts: [stmt_wrap])
      double('result', tree: tree)
    end

    before do
      require 'aws_ruby_database_driver_wrapper/utils/parser/pg_statement_analyzer'
      mod = Module.new { def self.parse(_sql) = raise 'not stubbed' }
      mod.const_set(:ParseError, Class.new(StandardError))
      stub_const('PgQuery', mod)
      allow(AwsRubyDatabaseDriverWrapper::Utils::Parser::PgStatementAnalyzer).to receive(:require).with('pg_query')
    end

    describe '#analyze_sql query_type' do
      it 'returns INSERT' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(insert_stmt: { relation: { relname: 'users' },
                                 cols: [{ res_target: { name: 'name' } },
                                        { res_target: { name: 'email' } }] })
        )
        expect(pg_parser.analyze_sql('INSERT INTO users (name, email) VALUES ($1, $2)').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::INSERT)
      end

      it 'returns UPDATE' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(update_stmt: { relation: { relname: 'users' },
                                 target_list: [{ res_target: { name: 'name', val: { param_ref: { number: 1 } } } }],
                                 where_clause: nil })
        )
        expect(pg_parser.analyze_sql('UPDATE users SET name = $1 WHERE id = $2').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UPDATE)
      end

      it 'returns SELECT' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(select_stmt: { from_clause: [{ range_var: { relname: 'customers' } }],
                                 where_clause: nil, locking_clause: [] })
        )
        expect(pg_parser.analyze_sql('SELECT * FROM customers WHERE id = $1').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
      end

      it 'returns UNKNOWN for nil' do
        expect(pg_parser.analyze_sql(nil).query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
      end
    end

    describe '#analyze_sql affected_tables' do
      it 'returns the table for SELECT' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(select_stmt: { from_clause: [{ range_var: { relname: 'customers' } }],
                                 where_clause: nil, locking_clause: [] })
        )
        expect(pg_parser.analyze_sql('SELECT * FROM customers WHERE id = $1').affected_tables).to include('customers')
      end

      it 'includes both tables for SELECT with JOIN' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(select_stmt: {
                    from_clause: [{ join_expr: {
                      larg: { range_var: { relname: 'customers' } },
                      rarg: { range_var: { relname: 'orders' } }
                    } }],
                    where_clause: nil, locking_clause: []
                  })
        )
        result = pg_parser.analyze_sql('SELECT c.name, o.total FROM customers c JOIN orders o ON c.id = o.customer_id')
        expect(result.affected_tables).to include('customers', 'orders')
      end

      it 'returns the table for INSERT' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(insert_stmt: { relation: { relname: 'users' },
                                 cols: [{ res_target: { name: 'name' } },
                                        { res_target: { name: 'email' } }] })
        )
        expect(pg_parser.analyze_sql('INSERT INTO users (name, email) VALUES ($1, $2)').affected_tables).to include('users')
      end

      it 'strips schema prefix' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(insert_stmt: { relation: { relname: 'users' }, cols: [] })
        )
        expect(pg_parser.analyze_sql('INSERT INTO public.users (id) VALUES (1)').affected_tables).to include('users')
      end

      it 'returns empty set for nil' do
        expect(pg_parser.analyze_sql(nil).affected_tables).to be_empty
      end
    end

    describe '#column_parameter_mapping' do
      it 'maps the column list for INSERT' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(insert_stmt: { relation: { relname: 'users' },
                                 cols: [{ res_target: { name: 'name' } },
                                        { res_target: { name: 'email' } }],
                                 select_stmt: { select_stmt: { values_lists: [
                                   { list: { items: [{ param_ref: { number: 1 } },
                                                     { param_ref: { number: 2 } }] } }
                                 ] } } })
        )
        expect(pg_parser.column_parameter_mapping('INSERT INTO users (name, email) VALUES ($1, $2)')).to eq({ 1 => 'name', 2 => 'email' })
      end

      it 'maps SET columns only for UPDATE' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(update_stmt: {
                    relation: { relname: 'users' },
                    target_list: [
                      { res_target: { name: 'name',  val: { param_ref: { number: 1 } } } },
                      { res_target: { name: 'email', val: { param_ref: { number: 2 } } } }
                    ],
                    where_clause: {
                      a_expr: {
                        lexpr: { column_ref: { fields: [{ string: { sval: 'id' } }] } },
                        rexpr: { param_ref: { number: 3 } }
                      }
                    }
                  })
        )
        expect(pg_parser.column_parameter_mapping('UPDATE users SET name = $1, email = $2 WHERE id = $3')).to eq({ 1 => 'name',
                                                                                                                   2 => 'email' })
      end

      it 'maps WHERE columns only for SELECT' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(select_stmt: {
                    from_clause: [{ range_var: { relname: 'users' } }],
                    where_clause: {
                      a_expr: {
                        lexpr: { column_ref: { fields: [{ string: { sval: 'name' } }] } },
                        rexpr: { param_ref: { number: 1 } }
                      }
                    },
                    locking_clause: []
                  })
        )
        expect(pg_parser.column_parameter_mapping('SELECT ssn FROM users WHERE name = $1')).to eq({ 1 => 'name' })
      end

      it 'returns empty for DELETE' do
        allow(PgQuery).to receive(:parse).and_return(
          pg_stmt(delete_stmt: { relation: { relname: 'users' }, where_clause: nil })
        )
        expect(pg_parser.column_parameter_mapping('DELETE FROM users WHERE id = $1')).to eq({})
      end

      it 'returns empty for nil' do
        expect(pg_parser.column_parameter_mapping(nil)).to eq({})
      end
    end
  end

  # The write-side fail-closed logic keys off unbound_write_columns and write_columns_complete.
  # These exercise the real pg_query analyzer end-to-end (no stubbed AST) to lock in that behavior.
  context 'with PostgreSQL dialect (write-side fail-closed fields)' do
    subject(:pg_parser) { described_class.new(pg_dialect) }

    describe '#analyze_sql write_columns_complete' do
      it 'is false for an INSERT with no column list' do
        expect(pg_parser.analyze_sql('INSERT INTO customers VALUES ($1, $2)').write_columns_complete).to be(false)
      end

      it 'is false for a multi-statement string' do
        sql = 'INSERT INTO customers (name) VALUES ($1); UPDATE customers SET email = $2 WHERE id = $3'
        expect(pg_parser.analyze_sql(sql).write_columns_complete).to be(false)
      end
    end

    describe '#analyze_sql unbound_write_columns' do
      it 'includes a column filled with DEFAULT rather than a bind parameter' do
        result = pg_parser.analyze_sql('INSERT INTO customers (name, created_at) VALUES ($1, DEFAULT)')
        expect(result.unbound_write_columns.map(&:column_name)).to include('created_at')
      end

      it 'includes a column filled with an expression around a bind parameter' do
        result = pg_parser.analyze_sql('INSERT INTO customers (name, score) VALUES ($1, $2 + 1)')
        expect(result.unbound_write_columns.map(&:column_name)).to include('score')
      end
    end

    describe '#analyze_sql for COPY ... FROM' do
      it 'reports query_type COPY with its named columns as unbound writes' do
        result = pg_parser.analyze_sql('COPY customers (name, email) FROM STDIN')
        expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::COPY)
        expect(result.unbound_write_columns.map(&:column_name)).to include('name', 'email')
      end
    end
  end
end
