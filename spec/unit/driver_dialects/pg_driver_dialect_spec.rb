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

require 'aws_ruby_database_driver_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/postgresql'

require 'concurrent'

RSpec.describe AwsRubyDatabaseDriverWrapper::DriverDialects::PgDriverDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double('PG::Connection', finished?: false) }
  let(:host_info) { AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 5432) }
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
      no_host = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
        host: AwsRubyDatabaseDriverWrapper::Host::HostInfo::NO_HOST, port: '5432'
      )
      result = dialect.prepare_connect_config(no_host, config)
      expect(result).not_to have_key(:host)
      expect(result[:port]).to eq('5432')
    end

    it 'omits both host and port when neither specified' do
      bare = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new
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

  describe '#network_bound_methods' do
    it 'returns a frozen Set' do
      expect(dialect.network_bound_methods).to be_a(Set)
      expect(dialect.network_bound_methods).to be_frozen
    end

    it 'includes CONNECTION_EXEC' do
      expect(dialect.network_bound_methods).to include(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_EXEC.name)
    end

    it 'excludes CONNECTION_ESCAPE' do
      expect(dialect.network_bound_methods).not_to include(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_ESCAPE.name)
    end

    # A call that is not listed here is handed straight to the driver, which takes it past every
    # plugin. The calls that run a statement or move its results are the ones that must never be
    # missed, so they are checked against the driver itself rather than against a list written out by
    # hand, which is what let several spellings of exec go unlisted to begin with.
    it 'covers every pg call that runs a statement or moves its results' do
      wrapper = AwsRubyDatabaseDriverWrapper::WrapperPgConnection
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
      common = AwsRubyDatabaseDriverWrapper::DriverDialects::DriverDialect::COMMON_NETWORK_BOUND_METHODS
      defined_by_pg = [PG::Connection, PG::Result].flat_map(&:instance_methods).to_set

      unanswerable = (dialect.network_bound_methods - common).reject do |entry|
        defined_by_pg.include?(entry.split('.', 2).last.to_sym)
      end

      expect(unanswerable).to be_empty
    end
  end
end
