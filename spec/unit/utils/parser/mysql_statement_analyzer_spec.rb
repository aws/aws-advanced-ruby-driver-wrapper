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
require 'aws_ruby_database_driver_wrapper/utils/parser/mysql_statement_analyzer'
require 'aws_ruby_database_driver_wrapper/utils/parser/query_type'

RSpec.describe AwsRubyDatabaseDriverWrapper::Utils::Parser::MysqlStatementAnalyzer do
  subject { described_class }

  describe '.analyze query_type' do
    it 'returns SELECT for a plain SELECT' do
      expect(subject.analyze('SELECT name, age FROM users WHERE id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
    end

    it 'returns SELECT for a backtick SELECT' do
      expect(subject.analyze('SELECT `user_id`, `email` FROM `users` WHERE `id` = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
    end

    it 'returns SELECT for lowercase select' do
      expect(subject.analyze('select `name` from `users` where `id` = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
    end

    it 'returns INSERT' do
      expect(subject.analyze('INSERT INTO users (name, email) VALUES (?, ?)').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::INSERT)
    end

    it 'returns INSERT for backtick INSERT' do
      expect(subject.analyze('INSERT INTO `users` (`name`, `email`) VALUES (?, ?)').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::INSERT)
    end

    it 'returns UPDATE' do
      expect(subject.analyze('UPDATE users SET name = ?, email = ? WHERE id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UPDATE)
    end

    it 'returns UPDATE for backtick UPDATE' do
      expect(subject.analyze('UPDATE `users` SET `name` = ?, `email` = ? WHERE `id` = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UPDATE)
    end

    it 'returns DELETE' do
      expect(subject.analyze('DELETE FROM users WHERE id = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::DELETE)
    end

    it 'returns DELETE for backtick DELETE' do
      expect(subject.analyze('DELETE FROM `users` WHERE `id` = ?').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::DELETE)
    end

    it 'returns CREATE for CREATE TABLE' do
      expect(subject.analyze('CREATE TABLE new_table (id INT PRIMARY KEY, name VARCHAR(100))').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::CREATE)
    end

    it 'returns DROP for DROP TABLE' do
      expect(subject.analyze('DROP TABLE old_table').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::DROP)
    end

    it 'returns UNKNOWN for unrecognized SQL' do
      expect(subject.analyze('INVALID SQL STATEMENT').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end

    it 'returns UNKNOWN for nil' do
      expect(subject.analyze(nil).query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end

    it 'returns UNKNOWN for empty string' do
      expect(subject.analyze('').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end

    it 'returns UNKNOWN for whitespace only' do
      expect(subject.analyze('   ').query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::UNKNOWN)
    end
  end

  describe '.analyze tables' do
    it 'extracts table from plain SELECT' do
      expect(subject.analyze('SELECT name FROM users WHERE id = ?').tables).to include('users')
    end

    it 'strips backticks from table name' do
      expect(subject.analyze('SELECT `name` FROM `users` WHERE `id` = ?').tables).to include('users')
    end

    it 'extracts both tables from JOIN' do
      result = subject.analyze('SELECT u.name, o.total FROM users u JOIN orders o ON u.id = o.user_id WHERE u.id = ?')
      expect(result.tables).to include('users', 'orders')
    end

    it 'extracts tables from subquery' do
      result = subject.analyze('SELECT `name` FROM `users` WHERE `id` IN (SELECT `user_id` FROM `orders` WHERE `total` > ?)')
      expect(result.tables.size).to be >= 2
    end

    it 'extracts tables from UNION' do
      result = subject.analyze('SELECT `name` FROM `users` WHERE `id` = ? UNION SELECT `name` FROM `archived_users` WHERE `id` = ?')
      expect(result.tables.size).to be >= 2
    end

    it 'extracts table from INSERT' do
      expect(subject.analyze('INSERT INTO users (name, email) VALUES (?, ?)').tables).to include('users')
    end

    it 'extracts table from UPDATE' do
      expect(subject.analyze('UPDATE users SET name = ? WHERE id = ?').tables).to include('users')
    end

    it 'extracts table from DELETE' do
      expect(subject.analyze('DELETE FROM users WHERE id = ?').tables).to include('users')
    end

    it 'extracts table from CREATE TABLE' do
      expect(subject.analyze('CREATE TABLE `users` (`id` INT AUTO_INCREMENT PRIMARY KEY)').tables).to include('users')
    end

    it 'extracts table from DROP TABLE' do
      expect(subject.analyze('DROP TABLE `users`').tables).to include('users')
    end

    it 'handles double-quoted identifiers' do
      expect(subject.analyze('SELECT "name" FROM "users" WHERE "id" = ?').tables).not_to be_empty
    end
  end

  describe '.analyze columns' do
    it 'extracts columns from INSERT' do
      result = subject.analyze('INSERT INTO users (name, email) VALUES (?, ?)')
      expect(result.write_columns.map(&:column_name)).to eq(%w[name email])
    end

    it 'extracts columns from backtick INSERT' do
      result = subject.analyze('INSERT INTO `users` (`name`, `email`, `ssn`) VALUES (?, ?, ?)')
      expect(result.write_columns.map(&:column_name)).to eq(%w[name email ssn])
    end

    # Every row is reported, not just the first. A caller that encrypts a column has to know about
    # the parameters of rows two onwards as well, or it would send them in the clear.
    it 'reports a column of a multi-row INSERT once per row, with the parameter of that row' do
      result = subject.analyze('INSERT INTO `users` (`name`, `email`) VALUES (?, ?), (?, ?)')

      expect(result.write_columns.map(&:column_name)).to eq(%w[name email name email])
      expect(result.write_columns.map(&:parameter_index)).to eq([1, 2, 3, 4])
    end

    it 'extracts SET columns from UPDATE (only ? params)' do
      result = subject.analyze('UPDATE users SET name = ?, email = ? WHERE id = ?')
      expect(result.write_columns.map(&:column_name)).to eq(%w[name email])
    end

    it 'extracts SET columns from backtick UPDATE' do
      result = subject.analyze('UPDATE `users` SET `name` = ?, `email` = ? WHERE `id` = ?')
      expect(result.write_columns.size).to eq(2)
    end

    it 'extracts a single SET column from UPDATE' do
      result = subject.analyze('UPDATE customers SET name = ? WHERE id = ?')
      expect(result.write_columns.map(&:column_name)).to eq(['name'])
    end

    it 'extracts multiple SET columns from UPDATE' do
      result = subject.analyze('UPDATE products SET name = ?, price = ?, description = ? WHERE category = ?')
      expect(result.write_columns.map(&:column_name)).to eq(%w[name price description])
    end
  end

  describe '.analyze where_columns' do
    it 'extracts WHERE column from SELECT' do
      result = subject.analyze('SELECT name FROM users WHERE id = ?')
      expect(result.where_columns.map(&:column_name)).to include('id')
    end

    it 'extracts multiple WHERE columns' do
      result = subject.analyze('SELECT ssn, email FROM users WHERE name = ? AND age = ?')
      expect(result.where_columns.map(&:column_name)).to include('name', 'age')
    end

    it 'extracts WHERE columns from complex expression' do
      result = subject.analyze('SELECT `name` FROM `users` WHERE `age` > ? AND (`status` = ? OR `role` = ?)')
      expect(result.where_columns.size).to be >= 3
    end

    it 'returns empty where_columns when no ? in WHERE' do
      result = subject.analyze("SELECT ssn FROM users WHERE name = 'John'")
      expect(result.where_columns).to be_empty
    end

    it 'does not include WHERE columns in the UPDATE columns list' do
      result = subject.analyze('UPDATE users SET ssn = ?, email = ? WHERE id = ?')
      expect(result.write_columns.map(&:column_name)).to eq(%w[ssn email])
    end

    it 'extracts column from LIKE' do
      result = subject.analyze('SELECT name FROM users WHERE name LIKE ?')
      expect(result.where_columns.map(&:column_name)).to eq(['name'])
    end

    it 'extracts column from NOT LIKE' do
      result = subject.analyze('SELECT name FROM users WHERE name NOT LIKE ?')
      expect(result.where_columns.map(&:column_name)).to eq(['name'])
    end

    it 'extracts column from BETWEEN as two entries' do
      result = subject.analyze('SELECT name FROM users WHERE age BETWEEN ? AND ?')
      expect(result.where_columns.map(&:column_name)).to eq(%w[age age])
    end

    it 'extracts column from NOT BETWEEN as two entries' do
      result = subject.analyze('SELECT name FROM users WHERE age NOT BETWEEN ? AND ?')
      expect(result.where_columns.map(&:column_name)).to eq(%w[age age])
    end

    it 'preserves positional order across mixed operators' do
      result = subject.analyze('SELECT * FROM users WHERE name LIKE ? AND age BETWEEN ? AND ? AND status = ?')
      expect(result.where_columns.map(&:column_name)).to eq(%w[name age age status])
    end

    it 'returns empty where_columns for IS NULL (no ? parameter)' do
      result = subject.analyze('SELECT name FROM users WHERE deleted_at IS NULL')
      expect(result.where_columns).to be_empty
    end
  end

  describe '.analyze for_update' do
    it 'returns true for FOR UPDATE' do
      expect(subject.analyze('SELECT * FROM users WHERE id = 1 FOR UPDATE').for_update).to be true
    end

    it 'returns true for FOR SHARE' do
      expect(subject.analyze('SELECT * FROM users FOR SHARE').for_update).to be true
    end

    it 'returns true for FOR NO KEY UPDATE' do
      expect(subject.analyze('SELECT * FROM users FOR NO KEY UPDATE').for_update).to be true
    end

    it 'returns true for FOR KEY SHARE' do
      expect(subject.analyze('SELECT * FROM users FOR KEY SHARE').for_update).to be true
    end

    it 'returns false for a plain SELECT' do
      expect(subject.analyze('SELECT * FROM users WHERE id = 1').for_update).to be false
    end

    it 'returns false for INSERT' do
      expect(subject.analyze('INSERT INTO users (name) VALUES (?)').for_update).to be false
    end
  end

  describe '.analyze parameterized' do
    it 'returns true when SQL contains ?' do
      expect(subject.analyze('SELECT * FROM users WHERE id = ?').parameterized).to be true
    end

    it 'returns false when SQL has no ?' do
      expect(subject.analyze('SELECT * FROM users').parameterized).to be false
    end
  end

  describe 'MySQL-specific syntax' do
    it 'handles LIMIT' do
      result = subject.analyze('SELECT `name` FROM `users` WHERE `active` = ? LIMIT 10')
      expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
      expect(result.tables).to include('users')
    end

    it 'handles LIMIT OFFSET' do
      result = subject.analyze('SELECT `name` FROM `users` WHERE `active` = ? LIMIT 10 OFFSET 20')
      expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
    end

    it 'handles GROUP BY' do
      result = subject.analyze('SELECT `department`, COUNT(*) FROM `employees` WHERE `active` = ? GROUP BY `department`')
      expect(result.tables).to include('employees')
    end

    it 'handles HAVING' do
      result = subject.analyze('SELECT `department`, COUNT(*) as cnt FROM `employees` GROUP BY `department` HAVING cnt > ?')
      expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
    end

    it 'handles ON DUPLICATE KEY UPDATE' do
      result = subject.analyze('INSERT INTO `users` (`id`, `name`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `name` = ?')
      expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::INSERT)
      expect(result.tables).to include('users')
    end

    it 'handles reserved keyword as backtick column' do
      result = subject.analyze('SELECT `order`, `date` FROM `orders` WHERE `id` = ?')
      expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
      expect(result.tables).to include('orders')
    end

    it 'handles mixed quoting' do
      result = subject.analyze('SELECT `name`, email FROM users WHERE `id` = ?')
      expect(result.query_type).to eq(AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType::SELECT)
      expect(result.tables).to include('users')
    end
  end

  # A caller that substitutes a parameter has to know which parameter fills which column, and has to
  # know when a column is filled by something it cannot substitute at all.
  describe '.analyze write columns' do
    let(:query_type) { AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType }

    it 'pairs a column with the parameter that fills it, not with its position' do
      result = subject.analyze("INSERT INTO users (name, email, ssn) VALUES (?, 'x@y.z', ?)")

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['name', 1], ['ssn', 2]])
      expect(result.unbound_write_columns.map(&:column_name)).to eq(['email'])
    end

    it 'reads the SET form of an INSERT' do
      result = subject.analyze('INSERT INTO users SET name = ?, ssn = ?')

      expect(result.query_type).to eq(query_type::INSERT)
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['name', 1], ['ssn', 2]])
    end

    it 'reads a REPLACE as an INSERT' do
      result = subject.analyze('REPLACE INTO users (name, ssn) VALUES (?, ?)')

      expect(result.query_type).to eq(query_type::INSERT)
      expect(result.write_columns.map(&:column_name)).to eq(%w[name ssn])
    end

    it 'reports the assignments of an upsert as well as its values' do
      result = subject.analyze('INSERT INTO users (name, ssn) VALUES (?, ?) ON DUPLICATE KEY UPDATE ssn = ?')

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] })
        .to eq([['name', 1], ['ssn', 2], ['ssn', 3]])
    end

    it 'reports an INSERT with no column list as not enumerable' do
      result = subject.analyze('INSERT INTO users VALUES (?, ?)')

      expect(result.write_columns).to be_empty
      expect(result.write_columns_complete).to be(false)
      expect(result.tables).to include('users')
    end

    it 'reports an INSERT from a SELECT as not enumerable' do
      result = subject.analyze('INSERT INTO users (name, ssn) SELECT name, ssn FROM imported')

      expect(result.write_columns).to be_empty
      expect(result.write_columns_complete).to be(false)
    end

    it 'reports an expression around a parameter as a value it cannot substitute' do
      result = subject.analyze('UPDATE users SET ssn = upper(?) WHERE name = ?')

      expect(result.write_columns).to be_empty
      expect(result.unbound_write_columns.map(&:column_name)).to eq(['ssn'])
    end

    it 'passes over a column set to NULL' do
      result = subject.analyze('INSERT INTO users (name, ssn) VALUES (?, NULL)')

      expect(result.unbound_write_columns).to be_empty
      expect(result.write_columns_complete).to be(true)
    end

    # A comma inside a quoted value is part of the value, not a separator between two of them.
    it 'does not split a value on a comma inside a string' do
      result = subject.analyze("INSERT INTO users (name, ssn) VALUES ('Doe, Jo', ?)")

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['ssn', 1]])
      expect(result.unbound_write_columns.map(&:column_name)).to eq(['name'])
    end
  end

  # The keyword that says what a statement does is not always the first thing in the text. Query
  # instrumentation prepends a comment, and MySQL accepts a WITH clause in front of a statement that
  # writes as readily as in front of one that reads. Reading either as an unrecognized statement
  # would leave a write looking like a read, and its parameters would go to the database as they are.
  describe '.analyze past what precedes the keyword' do
    let(:query_type) { AwsRubyDatabaseDriverWrapper::Utils::Parser::QueryType }

    it 'reads an INSERT behind a block comment' do
      result = subject.analyze('/* app:checkout,controller:orders */ INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(result.query_type).to eq(query_type::INSERT)
      expect(result.tables).to include('users')
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['name', 1], ['ssn', 2]])
    end

    it 'reads an UPDATE behind a line comment' do
      result = subject.analyze("-- audit\nUPDATE users SET ssn = ? WHERE id = ?")

      expect(result.query_type).to eq(query_type::UPDATE)
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['ssn', 1]])
    end

    it 'reads an INSERT behind a hash comment' do
      result = subject.analyze("# audit\nINSERT INTO users SET name = ?, ssn = ?")

      expect(result.query_type).to eq(query_type::INSERT)
      expect(result.write_columns.map(&:column_name)).to eq(%w[name ssn])
    end

    it 'reads an INSERT behind a common table expression' do
      result = subject.analyze('WITH recent AS (SELECT 1) INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(result.query_type).to eq(query_type::INSERT)
      expect(result.tables).to eq(['users'])
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['name', 1], ['ssn', 2]])
    end

    it 'reads an UPDATE behind a recursive common table expression that names its columns' do
      result = subject.analyze('WITH RECURSIVE t (a) AS (SELECT 1) UPDATE users SET ssn = ? WHERE id = ?')

      expect(result.query_type).to eq(query_type::UPDATE)
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['ssn', 1]])
    end

    it 'reads an INSERT behind several common table expressions' do
      result = subject.analyze('WITH a AS (SELECT 1), b AS (SELECT 2) INSERT INTO users (ssn) VALUES (?)')

      expect(result.query_type).to eq(query_type::INSERT)
      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['ssn', 1]])
    end

    # A parameter of the common table expression is bound before the ones the statement writes, so
    # the numbering the caller sees starts past it.
    it 'counts the bind parameters of the common table expression before the ones it writes' do
      result = subject.analyze('WITH t AS (SELECT ? AS a) INSERT INTO users (name, ssn) VALUES (?, ?)')

      expect(result.write_columns.map { |c| [c.column_name, c.parameter_index] }).to eq([['name', 2], ['ssn', 3]])
    end

    it 'still reads the tables a common table expression reads on a SELECT' do
      result = subject.analyze('WITH t AS (SELECT * FROM audit) SELECT ssn FROM users WHERE id = ?')

      expect(result.query_type).to eq(query_type::SELECT)
      expect(result.tables).to include('users', 'audit')
    end

    # Nothing is guessed from a clause that would not come apart: what the statement is, and which
    # parameter fills which column, both depend on reading the clause through.
    it 'reports a statement behind a clause it cannot read as unknown' do
      result = subject.analyze('WITH t AS (SELECT ((( INSERT INTO users (ssn) VALUES (?)')

      expect(result.query_type).to eq(query_type::UNKNOWN)
      expect(result.tables).to be_empty
      expect(result.write_columns_complete).to be(false)
    end
  end
end
