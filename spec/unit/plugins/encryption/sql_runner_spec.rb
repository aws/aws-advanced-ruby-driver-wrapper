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
require 'aws_ruby_database_driver_wrapper/plugins/encryption/sql_runner'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::SqlRunner do
  # The runner picks its behaviour from the dialect class, so these have to be real dialects
  # rather than doubles.
  let(:pg_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect.new }
  let(:mysql_dialect) { AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect.new }
  let(:pg_runner) { described_class.new(pg_dialect) }
  let(:mysql_runner) { described_class.new(mysql_dialect) }
  let(:connection) { double('Connection') }

  describe '#pg?' do
    it 'is true for the pg dialect' do
      expect(pg_runner.pg?).to be(true)
    end

    it 'is false for the mysql2 dialect' do
      expect(mysql_runner.pg?).to be(false)
    end
  end

  describe '#translate' do
    it 'numbers the placeholders for pg' do
      expect(pg_runner.translate('INSERT INTO t (a, b, c) VALUES (?, ?, ?)'))
        .to eq('INSERT INTO t (a, b, c) VALUES ($1, $2, $3)')
    end

    it 'leaves the placeholders alone for mysql2' do
      expect(mysql_runner.translate('INSERT INTO t (a, b) VALUES (?, ?)'))
        .to eq('INSERT INTO t (a, b) VALUES (?, ?)')
    end

    it 'leaves SQL without placeholders alone' do
      expect(pg_runner.translate('SELECT 1')).to eq('SELECT 1')
    end
  end

  describe '#query' do
    it 'runs SQL without parameters through the dialect' do
      allow(pg_dialect).to receive(:execute).with(connection, 'SELECT 1').and_return([{ 'a' => 1 }])
      expect(pg_runner.query(connection, 'SELECT 1')).to eq([{ 'a' => 1 }])
    end

    it 'translates the placeholders of a parameterized query' do
      allow(pg_dialect).to receive(:execute_with_params)
        .with(connection, 'SELECT a FROM t WHERE b = $1', ['x']).and_return([{ 'a' => 1 }])
      expect(pg_runner.query(connection, 'SELECT a FROM t WHERE b = ?', ['x'])).to eq([{ 'a' => 1 }])
    end

    it 'keeps the placeholders of a parameterized query for mysql2' do
      allow(mysql_dialect).to receive(:execute_with_params)
        .with(connection, 'SELECT a FROM t WHERE b = ?', ['x']).and_return([{ 'a' => 1 }])
      expect(mysql_runner.query(connection, 'SELECT a FROM t WHERE b = ?', ['x'])).to eq([{ 'a' => 1 }])
    end

    it 'collects the rows into an array' do
      allow(pg_dialect).to receive(:execute).and_return([{ 'a' => 1 }, { 'a' => 2 }].each)
      expect(pg_runner.query(connection, 'SELECT 1')).to eq([{ 'a' => 1 }, { 'a' => 2 }])
    end

    # A DDL statement has no result to read.
    it 'is empty for a statement without a result' do
      allow(pg_dialect).to receive(:execute).and_return(nil)
      expect(pg_runner.query(connection, 'CREATE SCHEMA encrypt')).to eq([])

      allow(pg_dialect).to receive(:execute).and_return(:ok)
      expect(pg_runner.query(connection, 'CREATE SCHEMA encrypt')).to eq([])
    end

    it 'is available as #execute as well' do
      allow(pg_dialect).to receive(:execute).and_return([{ 'a' => 1 }])
      expect(pg_runner.execute(connection, 'SELECT 1')).to eq([{ 'a' => 1 }])
    end
  end

  describe '#update' do
    it 'reads the affected row count from the pg result' do
      allow(pg_dialect).to receive(:execute_with_params).and_return(double('PgResult', cmd_tuples: 2))
      expect(pg_runner.update(connection, 'DELETE FROM t WHERE a = ?', [1])).to eq(2)
    end

    it 'is zero when the pg result cannot report a row count' do
      allow(pg_dialect).to receive(:execute).and_return(double('PgResult'))
      expect(pg_runner.update(connection, 'DELETE FROM t')).to eq(0)
    end

    # mysql2 reports the count on the connection rather than on the result.
    it 'reads the affected row count from the mysql2 connection' do
      mysql_connection = double('Mysql2Connection', affected_rows: 3)
      allow(mysql_dialect).to receive(:execute_with_params).and_return(nil)
      expect(mysql_runner.update(mysql_connection, 'DELETE FROM t WHERE a = ?', [1])).to eq(3)
    end
  end

  describe '#insert_returning_id' do
    it 'asks pg to return the generated id' do
      allow(pg_dialect).to receive(:execute_with_params)
        .with(connection, 'INSERT INTO t (a) VALUES ($1) RETURNING id', ['x'])
        .and_return([{ 'id' => '7' }])

      expect(pg_runner.insert_returning_id(connection, 'INSERT INTO t (a) VALUES (?)', ['x'])).to eq(7)
    end

    it 'can return a different generated column' do
      allow(pg_dialect).to receive(:execute_with_params)
        .with(connection, 'INSERT INTO t (a) VALUES ($1) RETURNING key_id', ['x'])
        .and_return([{ 'key_id' => '7' }])

      expect(pg_runner.insert_returning_id(connection, 'INSERT INTO t (a) VALUES (?)', ['x'], id_column: 'key_id'))
        .to eq(7)
    end

    it 'is nil when pg returns no row' do
      allow(pg_dialect).to receive(:execute_with_params).and_return([])
      expect(pg_runner.insert_returning_id(connection, 'INSERT INTO t (a) VALUES (?)', ['x'])).to be_nil
    end

    # mysql2 has no RETURNING clause, so the id comes from the connection afterwards.
    it 'reads the last insert id from the mysql2 connection' do
      mysql_connection = double('Mysql2Connection', last_id: 7)
      allow(mysql_dialect).to receive(:execute_with_params)
        .with(mysql_connection, 'INSERT INTO t (a) VALUES (?)', ['x']).and_return(nil)

      expect(mysql_runner.insert_returning_id(mysql_connection, 'INSERT INTO t (a) VALUES (?)', ['x'])).to eq(7)
    end

    it 'is nil when mysql2 generated no id' do
      mysql_connection = double('Mysql2Connection', last_id: 0)
      allow(mysql_dialect).to receive(:execute_with_params).and_return(nil)

      expect(mysql_runner.insert_returning_id(mysql_connection, 'INSERT INTO t (a) VALUES (?)', ['x'])).to be_nil
    end
  end

  describe '#binary_param' do
    it 'marks the value as binary for pg' do
      expect(pg_runner.binary_param("\x00\xff".b)).to eq({ value: "\x00\xff".b, format: 1 })
    end

    it 'passes the bytes straight to mysql2' do
      param = mysql_runner.binary_param("\x00\xff".b)
      expect(param).to eq("\x00\xff".b)
      expect(param.encoding).to eq(Encoding::BINARY)
    end

    it 'is nil for a nil value' do
      expect(pg_runner.binary_param(nil)).to be_nil
      expect(mysql_runner.binary_param(nil)).to be_nil
    end
  end

  describe '#read_binary' do
    let(:bytes) { "\x00\x01\xfe\xff".b }

    # pg hands back a bytea column in its hex text format.
    it 'unescapes a pg bytea column' do
      expect(pg_runner.read_binary("\\x#{bytes.unpack1('H*')}")).to eq(bytes)
    end

    it 'unescapes the older octal bytea format as well' do
      expect(pg_runner.read_binary('\000\001\376\377')).to eq(bytes)
    end

    it 'reads a mysql2 blob column as binary' do
      value = bytes.dup.force_encoding(Encoding::UTF_8)
      expect(mysql_runner.read_binary(value)).to eq(bytes)
      expect(mysql_runner.read_binary(value).encoding).to eq(Encoding::BINARY)
    end

    it 'is nil for a nil value' do
      expect(pg_runner.read_binary(nil)).to be_nil
      expect(mysql_runner.read_binary(nil)).to be_nil
    end
  end
end
