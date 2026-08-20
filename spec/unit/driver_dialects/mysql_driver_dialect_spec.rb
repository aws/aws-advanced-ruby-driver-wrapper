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

require 'aws_ruby_database_driver_wrapper/driver_dialects/mysql_driver_dialect'
require 'aws_ruby_database_driver_wrapper/mysql'
require 'aws_ruby_database_driver_wrapper/host/host_info'

require 'concurrent'

RSpec.describe AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double('Mysql2::Client') }
  let(:host_info) { AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 3306) }
  let(:config) do
    Concurrent::Map.new.tap do |m|
      m[:database] = 'testdb'
      m[:username] = 'user'
    end
  end

  describe '#connect' do
    it 'calls Mysql2::Client.new with prepared config' do
      stub_const('Mysql2::Client', Class.new { def initialize(**_opts); end })
      expected = { database: 'testdb', username: 'user', host: 'db.example.com', port: 3306 }
      expect(Mysql2::Client).to receive(:new).with(**expected).and_return(connection)
      expect(dialect.connect(host_info, config)).to eq(connection)
    end
  end

  describe '#execute' do
    it 'delegates to connection.query' do
      expect(connection).to receive(:query).with('SELECT 1').and_return(:result)
      expect(dialect.execute(connection, 'SELECT 1')).to eq(:result)
    end
  end

  describe '#ping' do
    it 'returns true on success' do
      allow(connection).to receive(:ping).and_return(true)
      expect(dialect.ping(connection)).to be true
    end

    it 'returns false on error' do
      allow(connection).to receive(:ping).and_raise(StandardError)
      expect(dialect.ping(connection)).to be false
    end
  end

  describe '#closed?' do
    it 'delegates to connection.closed?' do
      allow(connection).to receive(:closed?).and_return(true)
      expect(dialect.closed?(connection)).to be true
    end
  end

  describe '#abort_connection' do
    it 'calls close' do
      allow(connection).to receive(:closed?).and_return(false)
      expect(connection).to receive(:close)
      dialect.close_connection(connection)
    end

    it 'suppresses errors' do
      allow(connection).to receive(:closed?).and_return(false)
      allow(connection).to receive(:close).and_raise(StandardError)
      expect { dialect.close_connection(connection) }.not_to raise_error
    end
  end

  describe '#sql_state' do
    it 'extracts sql_state from exception' do
      exception = double(sql_state: '42S02')
      expect(dialect.sql_state(exception)).to eq('42S02')
    end

    it 'returns nil for non-mysql errors' do
      expect(dialect.sql_state(StandardError.new)).to be_nil
    end
  end

  describe '#prepare_connect_config' do
    it 'sets host and port from HostInfo' do
      result = dialect.prepare_connect_config(host_info, config)
      expect(result[:host]).to eq('db.example.com')
      expect(result[:port]).to eq(3306)
    end

    it 'omits host when not specified (localhost default)' do
      no_host = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
        host: AwsRubyDatabaseDriverWrapper::Host::HostInfo::NO_HOST, port: '3306'
      )
      result = dialect.prepare_connect_config(no_host, config)
      expect(result).not_to have_key(:host)
      expect(result[:port]).to eq(3306)
    end

    it 'omits both host and port when neither specified' do
      bare = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new
      result = dialect.prepare_connect_config(bare, config)
      expect(result).not_to have_key(:host)
      expect(result).not_to have_key(:port)
    end

    it 'omits port when not specified' do
      no_port = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com')
      result = dialect.prepare_connect_config(no_port, config)
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

    it 'includes CONNECTION_QUERY' do
      expect(dialect.network_bound_methods).to include(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_QUERY.name)
    end

    it 'excludes CONNECTION_ESCAPE' do
      expect(dialect.network_bound_methods).not_to include(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_ESCAPE.name)
    end

    # A call that is not listed here is handed straight to the driver, which takes it past every
    # plugin. The calls that run a statement or move its results are the ones that must never be
    # missed, so they are checked against the driver itself rather than against a list written out by
    # hand, which is what let async_result go unlisted to begin with.
    it 'covers every mysql2 call that runs a statement or moves its results' do
      wrapper = AwsRubyDatabaseDriverWrapper::Mysql2WrapperClient
      # The client's own options, and the info libmysql buffered about the last statement, none of
      # which is a call to the server.
      local = %i[query_options query_info query_info_string]
      statement_calls = Mysql2::Client.instance_methods(false).grep(/query|prepare|result/) - local

      uncovered = statement_calls.reject do |method|
        dialect.network_bound_methods.include?("connection.#{method}") || wrapper.method_defined?(method)
      end

      expect(uncovered).to be_empty
    end

    # A name mysql2 does not answer to is a call the wrapper cannot make and an entry nothing can ever
    # match, which is how the client came to call query_async and more_results. The names inherited
    # from every dialect are left out: reset has no mysql2 counterpart and connect is not a call on a
    # connection at all.
    it 'names a method mysql2 defines for every call it lists of its own' do
      common = AwsRubyDatabaseDriverWrapper::DriverDialects::DriverDialect::COMMON_NETWORK_BOUND_METHODS
      defined_by_mysql2 = [Mysql2::Client, Mysql2::Result, Mysql2::Statement].flat_map(&:instance_methods).to_set

      unanswerable = (dialect.network_bound_methods - common).reject do |entry|
        defined_by_mysql2.include?(entry.split('.', 2).last.to_sym)
      end

      expect(unanswerable).to be_empty
    end

    # A listed call the client neither defines nor names in DYNAMIC_METHODS still reaches the plugins,
    # but as a bare string rather than a MethodInfo, and PluginManager only checks the bounded
    # connection of a MethodInfo. Such a call would be run on whatever connection is current, however
    # long ago the statement it is reading was sent. The names inherited from every dialect are left
    # out, as they are above: reset has no mysql2 counterpart and connect is not a call on a connection.
    it 'is answered by a client method or a DYNAMIC_METHODS entry for every call it lists of its own' do
      wrapper = AwsRubyDatabaseDriverWrapper::Mysql2WrapperClient
      common = AwsRubyDatabaseDriverWrapper::DriverDialects::DriverDialect::COMMON_NETWORK_BOUND_METHODS
      listed = (dialect.network_bound_methods - common).select { |entry| entry.start_with?('connection.') }

      unnamed = listed.reject do |entry|
        call = entry.delete_prefix('connection.').to_sym
        wrapper.method_defined?(call, false) || wrapper::DYNAMIC_METHODS.key?(call)
      end

      expect(unnamed).to be_empty
    end
  end
end
