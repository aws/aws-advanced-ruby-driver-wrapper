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

require_relative '../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'
require 'aws_advanced_ruby_driver_wrapper/errors'

RSpec.describe ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter do
  describe '#connect' do
    let(:base_config) do
      { adapter: 'aws_postgresql', host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com', port: 5432,
        database: 'mydb', username: 'myuser', password: 'secret' }
    end

    # Opens a connection with the given database.yml config and returns the config handed to the client.
    def client_config_for(config)
      client_config = nil
      allow(described_class).to receive(:new_client) do |passed|
        client_config = passed
        raise ActiveRecord::ConnectionNotEstablished, 'stop before connecting'
      end
      expect { described_class.new(config).connect! }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      client_config
    end

    it 'does not pass Active Record-only keys to the client' do
      ar_only = {
        pool: 5, max_connections: 5, min_connections: 1, keepalive: 60, max_age: 900, checkout_timeout: 5,
        idle_timeout: 60, reaping_frequency: 60, connection_retries: 1, retry_deadline: 5, replica: true,
        database_tasks: false, migrations_paths: 'db/cache_migrate', schema_dump: false,
        schema_cache_path: 'db/schema_cache.yml', use_metadata_table: false, statement_limit: 100,
        min_messages: 'warning', insert_returning: true, prepared_statements: true, variables: { timezone: 'UTC' },
        encoding: 'unicode', schema_search_path: 'public', advisory_locks: true, query_cache: 100, timeout: 5000
      }

      expect(client_config_for(base_config.merge(ar_only)).keys).not_to include(*ar_only.keys)
    end

    it 'passes pg connection options, mapping the Active Record user and database keys' do
      config = client_config_for(base_config.merge(sslmode: 'verify-full', connect_timeout: 10, application_name: 'app'))

      expect(config).to include(host: base_config[:host], port: 5432, dbname: 'mydb', user: 'myuser', password: 'secret',
                                sslmode: 'verify-full', connect_timeout: 10, application_name: 'app')
      expect(config.keys).not_to include(:username, :database, :adapter)
    end

    it 'passes wrapper properties and monitoring-prefixed keys' do
      credentials_provider = Object.new
      wrapper_props = {
        wrapper_plugins: 'failover,initial_connection', failover_timeout_sec: 60.0, cluster_id: 'my-cluster',
        aws_credentials_provider: credentials_provider, topology_monitoring_connect_timeout: 5,
        bg_monitoring_connect_timeout: 5
      }

      expect(client_config_for(base_config.merge(wrapper_props))).to include(wrapper_props)
    end
  end

  describe '.new_client' do
    let(:config) { { host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com', dbname: 'mydb', user: 'myuser' } }

    def connect_failing_with(message, client_config = config)
      allow(AwsAdvancedRubyDriverWrapper::WrapperPgConnection).to receive(:new).and_raise(PG::ConnectionBad, message)
      described_class.new_client(client_config)
    end

    it 'translates a missing database into NoDatabaseError' do
      expect { connect_failing_with('FATAL:  database "mydb" does not exist') }.to raise_error(ActiveRecord::NoDatabaseError)
    end

    it 'translates a failure on the postgres maintenance database into ConnectionNotEstablished' do
      expect { connect_failing_with('FATAL:  database "postgres" does not exist', config.merge(dbname: 'postgres')) }
        .to raise_error(ActiveRecord::ConnectionNotEstablished)
    end

    it 'translates a rejected user into DatabaseConnectionError' do
      expect { connect_failing_with('FATAL:  password authentication failed for user "myuser"') }
        .to raise_error(ActiveRecord::DatabaseConnectionError)
    end

    it 'translates an unreachable host into DatabaseConnectionError' do
      expect { connect_failing_with("could not translate host name \"#{config[:host]}\" to address") }
        .to raise_error(ActiveRecord::DatabaseConnectionError)
    end

    it 'translates any other pg error into ConnectionNotEstablished' do
      expect { connect_failing_with('server closed the connection unexpectedly') }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    end

    it 'does not translate wrapper errors' do
      error = AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError.new('no writer')
      allow(AwsAdvancedRubyDriverWrapper::WrapperPgConnection).to receive(:new).and_raise(error)

      expect { described_class.new_client(config) }.to raise_error(error)
    end
  end

  describe '#translate_exception' do
    let(:adapter) { described_class.allocate }
    let(:sql) { 'SELECT 1' }
    let(:binds) { [] }
    let(:message) { 'test error message' }

    context 'when exception is not an AwsError' do
      it 'returns the result of super (parent translate_exception)' do
        exception = StandardError.new('some non-aws error')
        parent_result = ActiveRecord::StatementInvalid.new(message, sql: sql, binds: binds)

        allow_any_instance_of(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
          .to receive(:translate_exception)
          .with(exception, message: message, sql: sql, binds: binds)
          .and_return(parent_result)

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to eq(parent_result)
      end
    end

    context 'when exception is a FailoverSuccessError' do
      it 'returns the original exception and reconfigures the connection' do
        exception = AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError.new
        allow(adapter).to receive(:configure_connection)

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to eq(exception)
        expect(adapter).to have_received(:configure_connection)
      end
    end

    context 'when exception is a TransactionStateUnknownError' do
      it 'returns the original exception and reconfigures the connection' do
        exception = AwsAdvancedRubyDriverWrapper::Errors::TransactionStateUnknownError.new
        allow(adapter).to receive(:configure_connection)

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to eq(exception)
        expect(adapter).to have_received(:configure_connection)
      end
    end

    context 'when exception is a FailoverFailedError' do
      it 'returns a connection error and sets connection_broken' do
        exception = AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError.new('')
        pool = double('pool')
        adapter.instance_variable_set(:@pool, pool)
        allow(adapter).to receive(:configure_connection)

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to be_a(ActiveRecord::ConnectionFailed)
        expect(adapter.instance_variable_get(:@connection_broken)).to be true
        # There is no usable connection to reconfigure when failover failed.
        expect(adapter).not_to have_received(:configure_connection)
      end
    end

    context 'when exception is a generic AwsError' do
      it 'returns the original exception unchanged' do
        exception = AwsAdvancedRubyDriverWrapper::Errors::AwsError.new('generic aws error')
        allow(adapter).to receive(:configure_connection)

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to eq(exception)
        expect(adapter).not_to have_received(:configure_connection)
      end
    end
  end
end
