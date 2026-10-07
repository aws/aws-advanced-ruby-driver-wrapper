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

require 'aws_advanced_ruby_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_advanced_ruby_driver_wrapper/host/host_info'
require 'aws_advanced_ruby_driver_wrapper/postgresql'

require 'concurrent'

RSpec.describe AwsAdvancedRubyDriverWrapper::DriverDialects::PgDriverDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double('PG::Connection', finished?: false) }
  let(:host_info) { AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 5432) }
  let(:config) do
    Concurrent::Map.new.tap do |m|
      m[:database] = 'testdb'
      m[:user] = 'pguser'
    end
  end

  describe '#connect' do
    it 'calls PG::Connection.new with prepared config' do
      expected = { dbname: 'testdb', user: 'pguser', host: 'db.example.com', port: 5432 }
      expect(PG::Connection).to receive(:new).with(**expected).and_return(connection)
      expect(dialect.connect(host_info, config)).to eq(connection)
    end
  end

  describe '#execute' do
    it 'delegates to connection.exec' do
      expect(connection).to receive(:exec).with('SELECT 1').and_return(:result)
      expect(dialect.execute(connection, 'SELECT 1')).to eq(:result)
    end
  end

  describe '#closed?' do
    it 'delegates to connection.finished?' do
      allow(connection).to receive(:finished?).and_return(true)
      expect(dialect.closed?(connection)).to be true
    end
  end

  describe '#abort_connection' do
    it 'calls close' do
      allow(connection).to receive(:finished?).and_return(false)
      expect(connection).to receive(:close)
      dialect.close_connection(connection)
    end

    it 'suppresses PG::Error' do
      allow(connection).to receive(:finished?).and_return(false)
      allow(connection).to receive(:close).and_raise(PG::Error)
      expect { dialect.close_connection(connection) }.not_to raise_error
    end
  end

  describe '#abandon_connection' do
    it 'points the socket at the null device instead of closing the connection' do
      socket_io = instance_double(IO)
      allow(connection).to receive_messages(finished?: false, socket_io: socket_io)
      expect(socket_io).to receive(:reopen).with(IO::NULL)
      expect(connection).not_to receive(:close)
      dialect.abandon_connection(connection)
    end

    it 'skips finished connections' do
      allow(connection).to receive(:finished?).and_return(true)
      expect(connection).not_to receive(:socket_io)
      dialect.abandon_connection(connection)
    end
  end

  describe '#sql_state' do
    it 'extracts SQLSTATE from PG::Error' do
      pg_result = double(error_field: '23505')
      exception = instance_double(PG::Error, result: pg_result)
      allow(exception).to receive(:is_a?).with(PG::Error).and_return(true)
      expect(dialect.sql_state(exception)).to eq('23505')
    end

    it 'returns nil for non-PG errors' do
      expect(dialect.sql_state(StandardError.new)).to be_nil
    end
  end

  describe '#prepare_connect_config' do
    it 'remaps :database to :dbname' do
      result = dialect.prepare_connect_config(host_info, config)
      expect(result[:dbname]).to eq('testdb')
      expect(result).not_to have_key(:database)
    end

    it 'preserves :dbname when already present' do
      cfg = Concurrent::Map.new.tap do |m|
        m[:dbname] = 'explicit'
        m[:database] = 'fallback'
        m[:user] = 'pguser'
      end
      result = dialect.prepare_connect_config(host_info, cfg)
      expect(result[:dbname]).to eq('explicit')
      expect(result).to have_key(:database)
    end

    it 'sets host and port from HostInfo' do
      result = dialect.prepare_connect_config(host_info, config)
      expect(result[:host]).to eq('db.example.com')
      expect(result[:port]).to eq(5432)
    end

    it 'omits host when not specified (Unix socket)' do
      no_host = AwsAdvancedRubyDriverWrapper::Host::HostInfo.new(
        host: AwsAdvancedRubyDriverWrapper::Host::HostInfo::NO_HOST, port: '5432'
      )
      result = dialect.prepare_connect_config(no_host, config)
      expect(result).not_to have_key(:host)
      expect(result[:port]).to eq('5432')
    end

    it 'omits both host and port when neither specified' do
      bare = AwsAdvancedRubyDriverWrapper::Host::HostInfo.new
      result = dialect.prepare_connect_config(bare, config)
      expect(result).not_to have_key(:host)
      expect(result).not_to have_key(:port)
    end

    it 'does not mutate the original config' do
      original = config.dup
      dialect.prepare_connect_config(host_info, config)
      expect(config.size).to eq(original.size)
      original.each { |k, v| expect(config[k]).to eq(v) }
    end
  end

  describe '#translate_placeholders' do
    it 'numbers the placeholders' do
      expect(dialect.translate_placeholders('INSERT INTO t (a, b) VALUES (?, ?)'))
        .to eq('INSERT INTO t (a, b) VALUES ($1, $2)')
    end

    it 'leaves SQL without placeholders alone' do
      expect(dialect.translate_placeholders('SELECT 1')).to eq('SELECT 1')
    end
  end

  describe '#binary_param' do
    it 'tags the bytes with binary format 1' do
      expect(dialect.binary_param("\x00\xff".b)).to eq({ value: "\x00\xff".b, format: 1 })
    end
  end

  describe '#read_binary' do
    it 'unescapes a hex bytea value' do
      bytes = "\x00\x01\xfe\xff".b
      expect(dialect.read_binary("\\x#{bytes.unpack1('H*')}")).to eq(bytes)
    end

    it 'unescapes an octal bytea value' do
      expect(dialect.read_binary('\000\001\376\377')).to eq("\x00\x01\xfe\xff".b)
    end
  end

  describe '#affected_rows' do
    it 'reads cmd_tuples from the result' do
      expect(dialect.affected_rows(connection, double('Result', cmd_tuples: 3))).to eq(3)
    end

    it 'is zero when the result cannot report a count' do
      expect(dialect.affected_rows(connection, double('Result'))).to eq(0)
    end
  end

  describe '#insert_returning_id' do
    it 'appends RETURNING and reads the generated id' do
      allow(connection).to receive(:exec_params)
        .with('INSERT INTO t (a) VALUES ($1) RETURNING id', ['x']).and_return([{ 'id' => '7' }])
      expect(dialect.insert_returning_id(connection, 'INSERT INTO t (a) VALUES ($1)', ['x'], 'id')).to eq(7)
    end

    it 'is nil when no row is returned' do
      allow(connection).to receive(:exec_params).and_return([])
      expect(dialect.insert_returning_id(connection, 'INSERT INTO t (a) VALUES ($1)', ['x'], 'id')).to be_nil
    end
  end

  describe '#upsert_clause' do
    it 'builds an ON CONFLICT DO UPDATE clause reading from EXCLUDED' do
      expect(dialect.upsert_clause(%w[table_name column_name], %w[algorithm key_id]))
        .to eq('ON CONFLICT (table_name, column_name) DO UPDATE SET algorithm = EXCLUDED.algorithm, key_id = EXCLUDED.key_id')
    end
  end

  describe '#foreign_key_query' do
    it 'reads foreign keys from information_schema with pg-numbered schema and table placeholders' do
      sql = dialect.foreign_key_query
      expect(sql).to include('FOREIGN KEY')
      expect(sql).to include('tc.table_schema OPERATOR(pg_catalog.=) $1 AND tc.table_name OPERATOR(pg_catalog.=) $2')
    end

    it 'compares only with the pg_catalog equality operator' do
      expect(dialect.foreign_key_query).not_to include(' = ')
    end
  end

  describe '#equals_operator' do
    it 'pins equality to pg_catalog so that the search_path cannot supply another operator' do
      expect(dialect.equals_operator).to eq('OPERATOR(pg_catalog.=)')
    end
  end

  describe '#reported_in_transaction' do
    it 'returns true when inside a valid transaction block' do
      allow(connection).to receive(:transaction_status).and_return(PG::PQTRANS_INTRANS)
      expect(dialect.reported_in_transaction(connection)).to be true
    end

    it 'returns true when inside a failed transaction block' do
      allow(connection).to receive(:transaction_status).and_return(PG::PQTRANS_INERROR)
      expect(dialect.reported_in_transaction(connection)).to be true
    end

    it 'returns false when idle' do
      allow(connection).to receive(:transaction_status).and_return(PG::PQTRANS_IDLE)
      expect(dialect.reported_in_transaction(connection)).to be false
    end

    it 'returns nil when a command is in progress (ACTIVE), deferring to SQL inference' do
      allow(connection).to receive(:transaction_status).and_return(PG::PQTRANS_ACTIVE)
      expect(dialect.reported_in_transaction(connection)).to be_nil
    end

    it 'returns nil when the connection state is unknown, deferring to SQL inference' do
      allow(connection).to receive(:transaction_status).and_return(PG::PQTRANS_UNKNOWN)
      expect(dialect.reported_in_transaction(connection)).to be_nil
    end

    it 'returns false when the connection raises PG::ConnectionBad' do
      allow(connection).to receive(:transaction_status).and_raise(PG::ConnectionBad)
      expect(dialect.reported_in_transaction(connection)).to be false
    end
  end

  describe '#network_bound_methods' do
    it 'returns a frozen Set' do
      expect(dialect.network_bound_methods).to be_a(Set)
      expect(dialect.network_bound_methods).to be_frozen
    end

    it 'includes CONNECTION_EXEC' do
      expect(dialect.network_bound_methods).to include(AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_EXEC.name)
    end

    it 'excludes CONNECTION_ESCAPE' do
      expect(dialect.network_bound_methods).not_to include(AwsAdvancedRubyDriverWrapper::RubyMethod::CONNECTION_ESCAPE.name)
    end

    # A call that is not listed here is handed straight to the driver, which takes it past every
    # plugin. The calls that run a statement or move its results are the ones that must never be
    # missed, so they are checked against the driver itself rather than against a list written out by
    # hand, which is what let several spellings of exec go unlisted to begin with.
    it 'covers every pg call that runs a statement or moves its results' do
      wrapper = AwsAdvancedRubyDriverWrapper::WrapperPgConnection
      # Accessors for the coder a COPY call uses, which do not talk to the server.
      local = %i[decoder_for_get_copy_data decoder_for_get_copy_data= encoder_for_put_copy_data encoder_for_put_copy_data=]
      statement_calls = PG::Connection.instance_methods(false).grep(
        /exec|query|prepare|copy_data|copy_end|get_result|get_last_result|discard_results/
      ) - local

      uncovered = statement_calls.reject do |method|
        canonical = wrapper::OPERATION_BY_SPELLING[method] || method
        dialect.network_bound_methods.include?("connection.#{canonical}") || wrapper.method_defined?(canonical)
      end

      expect(uncovered).to be_empty
    end

    # A name pg does not answer to is a call the wrapper cannot make and an entry nothing can ever
    # match. The names inherited from every dialect are left out: pg has no
    # prepared statement object of its own, and connect is not a call on a connection at all.
    it 'names a method pg defines for every call it lists of its own' do
      common = AwsAdvancedRubyDriverWrapper::DriverDialects::DriverDialect::COMMON_NETWORK_BOUND_METHODS
      defined_by_pg = [PG::Connection, PG::Result].flat_map(&:instance_methods).to_set

      unanswerable = (dialect.network_bound_methods - common).reject do |entry|
        defined_by_pg.include?(entry.split('.', 2).last.to_sym)
      end

      expect(unanswerable).to be_empty
    end
  end
end
