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

require 'trilogy'
require 'aws_advanced_ruby_driver_wrapper/driver_dialects/trilogy_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'

require 'concurrent'

RSpec.describe AwsAdvancedRubyDriverWrapper::DriverDialects::TrilogyDriverDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double(Trilogy, closed?: false) }
  let(:host_info) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 3306) }
  let(:config) do
    Concurrent::Map.new.tap do |m|
      m[:database] = 'testdb'
      m[:username] = 'user'
    end
  end

  def trilogy_result(fields, rows)
    Trilogy::Result.new(fields, rows, 0.0, false, 0, 0)
  end

  describe '#database_engine' do
    it 'is MySQL' do
      expect(dialect.database_engine).to eq(:mysql)
    end
  end

  describe '#connect' do
    it 'calls Trilogy.new with the prepared config' do
      expected = { database: 'testdb', username: 'user', host: 'db.example.com', port: 3306 }
      expect(Trilogy).to receive(:new).with(expected).and_return(connection)

      expect(dialect.connect(host_info, config)).to eq(connection)
    end

    it 'hands trilogy a hash of its own, since Trilogy.new writes to the hash it is given' do
      passed = []
      allow(Trilogy).to receive(:new) { |options| passed << options }

      2.times { dialect.connect(host_info, config) }

      expect(passed[0]).not_to equal(passed[1])
    end
  end

  describe '#execute' do
    it 'returns each row as a hash keyed by column name, as the mysql2 driver does' do
      result = trilogy_result(%w[id name], [[1, 'a'], [2, 'b']])
      allow(connection).to receive(:query).with('SELECT id, name FROM t').and_return(result)

      expect(dialect.execute(connection, 'SELECT id, name FROM t'))
        .to eq([{ 'id' => 1, 'name' => 'a' }, { 'id' => 2, 'name' => 'b' }])
    end

    it 'returns no rows for a statement that produces none' do
      allow(connection).to receive(:query).and_return(trilogy_result(nil, nil))

      expect(dialect.execute(connection, 'ROLLBACK')).to eq([])
    end
  end

  describe '#execute_with_params' do
    before { allow(connection).to receive(:escape) { |value| value.gsub("'", "\\\\'") } }

    it 'binds string parameters as escaped literals' do
      expect(connection).to receive(:query).with("SELECT region FROM t WHERE id = 'it\\'s'")
                                           .and_return(trilogy_result(%w[region], [['us-east-1']]))

      expect(dialect.execute_with_params(connection, 'SELECT region FROM t WHERE id = ?', ["it's"]))
        .to eq([{ 'region' => 'us-east-1' }])
    end

    it 'binds integers and nil as plain literals' do
      expect(connection).to receive(:query).with('UPDATE t SET a = 7, b = NULL').and_return(trilogy_result(nil, nil))

      dialect.execute_with_params(connection, 'UPDATE t SET a = ?, b = ?', [7, nil])
    end

    it 'does not read a question mark inside a bound value as another placeholder' do
      expect(connection).to receive(:query).with("SELECT 'a?b', 'c'").and_return(trilogy_result(nil, nil))

      dialect.execute_with_params(connection, 'SELECT ?, ?', ['a?b', 'c'])
    end

    it 'refuses a value it cannot write as a literal' do
      expect { dialect.execute_with_params(connection, 'SELECT ?', [1.5]) }.to raise_error(ArgumentError, /Float/)
    end

    it 'refuses a parameter count that does not match the placeholders' do
      expect { dialect.execute_with_params(connection, 'SELECT ?, ?', ['a']) }.to raise_error(ArgumentError, /2 placeholders/)
    end
  end

  describe '#ping' do
    it 'returns true on success' do
      allow(connection).to receive(:ping).and_return(true)
      expect(dialect.ping(connection)).to be true
    end

    it 'returns false on error' do
      allow(connection).to receive(:ping).and_raise(Trilogy::EOFError, 'eof')
      expect(dialect.ping(connection)).to be false
    end
  end

  describe '#closed?' do
    it 'delegates to the connection' do
      allow(connection).to receive(:closed?).and_return(true)
      expect(dialect.closed?(connection)).to be true
    end

    it 'is true for no connection' do
      expect(dialect.closed?(nil)).to be true
    end
  end

  describe '#close_connection' do
    it 'closes an open connection' do
      expect(connection).to receive(:close)
      dialect.close_connection(connection)
    end

    it 'leaves a closed connection alone' do
      allow(connection).to receive(:closed?).and_return(true)
      expect(connection).not_to receive(:close)
      dialect.close_connection(connection)
    end

    it 'suppresses errors' do
      allow(connection).to receive(:close).and_raise(Trilogy::EOFError, 'eof')
      expect { dialect.close_connection(connection) }.not_to raise_error
    end
  end

  describe '#reported_in_transaction' do
    it 'reads the transaction state the server reports on the connection' do
      allow(connection).to receive(:in_transaction?).and_return(true)
      expect(dialect.reported_in_transaction(connection)).to be true
    end

    it 'is nil without an open connection, leaving the state to SQL inference' do
      allow(connection).to receive(:closed?).and_return(true)
      expect(dialect.reported_in_transaction(connection)).to be_nil
    end
  end

  describe '#abandon_connection' do
    it 'discards the connection instead of closing it' do
      expect(connection).to receive(:discard!)
      expect(connection).not_to receive(:close)
      dialect.abandon_connection(connection)
    end

    it 'does nothing for a closed connection' do
      allow(connection).to receive(:closed?).and_return(true)
      expect(connection).not_to receive(:discard!)
      dialect.abandon_connection(connection)
    end
  end

  describe '#sql_state' do
    it 'is nil, as trilogy errors carry only an error code' do
      expect(dialect.sql_state(Trilogy::ProtocolError.from_code('read only', 1290))).to be_nil
    end
  end

  describe '#network_bound_methods' do
    it 'includes the trilogy calls that reach the server' do
      expect(dialect.network_bound_methods).to include(
        'connection.query', 'connection.change_db', 'connection.next_result',
        'connection.abandon_results!', 'connection.set_server_option'
      )
    end

    it 'leaves out calls that trilogy answers locally' do
      expect(dialect.network_bound_methods).not_to include('connection.escape', 'result.each')
    end

    # ActiveRecord checks a connection is alive with ping and reconnects when it raises a trilogy
    # error; failover inside that check would raise a wrapper error out of it instead.
    it 'leaves out ping, so that a liveness check does not fail over' do
      expect(dialect.network_bound_methods).not_to include('connection.ping')
    end
  end

  describe '#apply_monitoring_defaults' do
    it 'sets timeouts the user has not set' do
      props = { read_timeout: 30 }
      dialect.apply_monitoring_defaults(props)
      expect(props).to eq(read_timeout: 30, write_timeout: 5, connect_timeout: 5)
    end
  end
end
