# frozen_string_literal: true

require 'aws_ruby_database_driver_wrapper/driver_dialects/mysql_driver_dialect'
require 'aws_ruby_database_driver_wrapper/host/host_info'

RSpec.describe AwsRubyDatabaseDriverWrapper::DriverDialects::MysqlDriverDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double('Mysql2::Client') }
  let(:host_info) { AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com', port: 3306) }
  let(:config) { { database: 'testdb', username: 'user' } }

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
      expect(connection).to receive(:close)
      dialect.close_connection(connection)
    end

    it 'suppresses errors' do
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

    it 'omits port when not specified' do
      no_port = AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(host: 'db.example.com')
      result = dialect.prepare_connect_config(no_port, config)
      expect(result).not_to have_key(:port)
    end

    it 'does not mutate the original config' do
      original = config.dup
      dialect.prepare_connect_config(host_info, config)
      expect(config).to eq(original)
    end
  end

  describe '#network_bound_methods' do
    it 'returns a frozen Set' do
      expect(dialect.network_bound_methods).to be_a(Set)
      expect(dialect.network_bound_methods).to be_frozen
    end

    it 'includes CONNECTION_QUERY' do
      expect(dialect.network_bound_methods).to include(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_QUERY)
    end

    it 'excludes CONNECTION_ESCAPE' do
      expect(dialect.network_bound_methods).not_to include(AwsRubyDatabaseDriverWrapper::RubyMethod::CONNECTION_ESCAPE)
    end
  end
end
