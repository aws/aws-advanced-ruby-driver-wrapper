# frozen_string_literal: true

require 'aws_advanced_ruby_wrapper/driver_dialects/pg_driver_dialect'
require 'aws_advanced_ruby_wrapper/host/host_info'

RSpec.describe AwsAdvancedRubyWrapper::DriverDialects::PgDriverDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double('PG::Connection') }
  let(:host_info) { AwsAdvancedRubyWrapper::Host::HostInfo.new(host: 'db.example.com', port: 5432) }
  let(:config) { { database: 'testdb', user: 'pguser' } }

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

  describe '#ping' do
    it 'returns true on success' do
      allow(connection).to receive(:exec).with('SELECT 1').and_return(:result)
      expect(dialect.ping(connection)).to be true
    end

    it 'returns false on PG::Error' do
      allow(connection).to receive(:exec).and_raise(PG::Error)
      expect(dialect.ping(connection)).to be false
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
      expect(connection).to receive(:close)
      dialect.close_connection(connection)
    end

    it 'suppresses PG::Error' do
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
      cfg = { dbname: 'explicit', database: 'fallback', user: 'pguser' }
      result = dialect.prepare_connect_config(host_info, cfg)
      expect(result[:dbname]).to eq('explicit')
      expect(result).to have_key(:database)
    end

    it 'sets host and port from HostInfo' do
      result = dialect.prepare_connect_config(host_info, config)
      expect(result[:host]).to eq('db.example.com')
      expect(result[:port]).to eq(5432)
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

    it 'includes CONNECTION_EXEC' do
      expect(dialect.network_bound_methods).to include(AwsAdvancedRubyWrapper::RubyMethod::CONNECTION_EXEC)
    end

    it 'excludes CONNECTION_ESCAPE' do
      expect(dialect.network_bound_methods).not_to include(AwsAdvancedRubyWrapper::RubyMethod::CONNECTION_ESCAPE)
    end
  end
end
