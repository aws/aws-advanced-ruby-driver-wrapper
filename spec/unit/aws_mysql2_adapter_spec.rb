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
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_mysql2_adapter'
require 'aws_advanced_ruby_driver_wrapper/errors'

RSpec.describe ActiveRecord::ConnectionAdapters::AwsMysql2Adapter do
  describe '.new_client' do
    let(:config) do
      { host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com', database: 'mydb', username: 'myuser', password: 'secret' }
    end

    it 'passes the mysql2 client options that ActiveRecord sets' do
      client_options = { encoding: 'utf8mb4', socket: '/tmp/mysql.sock', flags: Mysql2::Client::FOUND_ROWS, reconnect: false }
      allow(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to receive(:new)

      described_class.new_client(config.merge(client_options))

      expect(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to have_received(:new).with(hash_including(client_options))
    end

    it 'passes the config through unchanged, as the parent adapter does' do
      full_config = config.merge(adapter: 'aws_mysql2', pool: 5, max_connections: 5, replica: true,
                                 variables: { sql_mode: 'STRICT_ALL_TABLES' }, wrapper_plugins: 'failover')
      allow(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to receive(:new)

      described_class.new_client(full_config)

      expect(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to have_received(:new).with(**full_config)
    end

    it 'keeps the FOUND_ROWS flag the adapter adds when connecting' do
      passed = nil
      allow(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to receive(:new) do |**options|
        passed = options
        raise Mysql2::Error.new('stop before connecting', nil, 2003)
      end

      expect { described_class.new(config.merge(adapter: 'aws_mysql2')).connect! }.to raise_error(ActiveRecord::ActiveRecordError)
      expect(passed[:flags] & Mysql2::Client::FOUND_ROWS).to eq(Mysql2::Client::FOUND_ROWS)
    end

    {
      1049 => ActiveRecord::NoDatabaseError,
      1044 => ActiveRecord::DatabaseConnectionError,
      1045 => ActiveRecord::DatabaseConnectionError,
      2003 => ActiveRecord::DatabaseConnectionError,
      2005 => ActiveRecord::DatabaseConnectionError,
      1040 => ActiveRecord::ConnectionNotEstablished
    }.each do |error_number, translated|
      it "translates MySQL error #{error_number} into #{translated}" do
        allow(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to receive(:new)
          .and_raise(Mysql2::Error.new('connect failed', nil, error_number))

        expect { described_class.new_client(config) }.to raise_error(translated)
      end
    end

    it 'does not translate wrapper errors' do
      error = AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError.new('no writer')
      allow(AwsAdvancedRubyDriverWrapper::WrapperMysql2Client).to receive(:new).and_raise(error)

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

        allow_any_instance_of(ActiveRecord::ConnectionAdapters::Mysql2Adapter)
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
