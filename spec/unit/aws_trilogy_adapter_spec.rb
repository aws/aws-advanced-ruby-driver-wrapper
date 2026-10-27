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
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_trilogy_adapter'
require 'aws_advanced_ruby_driver_wrapper/errors'

RSpec.describe ActiveRecord::ConnectionAdapters::AwsTrilogyAdapter do
  describe '.new_client' do
    let(:config) do
      { host: 'my-cluster.cluster-xyz.us-east-1.rds.amazonaws.com', database: 'mydb', username: 'myuser', password: 'secret' }
    end

    it 'passes the config through to the wrapper, as the parent adapter passes it to trilogy' do
      full_config = config.merge(adapter: 'aws_trilogy', pool: 5, found_rows: true,
                                 variables: { sql_mode: 'STRICT_ALL_TABLES' }, wrapper_plugins: 'failover')
      allow(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to receive(:new)

      described_class.new_client(full_config)

      expect(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to have_received(:new).with(full_config)
    end

    it 'turns an ssl_mode name into the constant trilogy reads, as the parent adapter does' do
      allow(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to receive(:new)

      described_class.new_client(config.merge(ssl_mode: 'required'))

      expect(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient)
        .to have_received(:new).with(hash_including(ssl_mode: Trilogy::SSL_REQUIRED_NOVERIFY))
    end

    it 'keeps the FOUND_ROWS option the adapter adds when connecting' do
      passed = nil
      allow(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to receive(:new) do |options|
        passed = options
        raise Trilogy::BaseConnectionError, 'stop before connecting'
      end

      expect { described_class.new(config.merge(adapter: 'aws_trilogy')).connect! }
        .to raise_error(ActiveRecord::ActiveRecordError)
      expect(passed[:found_rows]).to be true
    end

    {
      1049 => ActiveRecord::NoDatabaseError,
      1044 => ActiveRecord::NoDatabaseError,
      1045 => ActiveRecord::DatabaseConnectionError,
      1040 => ActiveRecord::ConnectionNotEstablished
    }.each do |error_code, translated|
      it "translates MySQL error #{error_code} into #{translated}, as the parent adapter does" do
        allow(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to receive(:new)
          .and_raise(Trilogy::ProtocolError.from_code('connect failed', error_code))

        expect { described_class.new_client(config) }.to raise_error(translated)
      end
    end

    it 'translates a host that does not resolve into a hostname error' do
      allow(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to receive(:new)
        .and_raise(Trilogy::BaseConnectionError, 'trilogy_connect: TRILOGY_DNS_ERROR')

      expect { described_class.new_client(config) }.to raise_error(ActiveRecord::DatabaseConnectionError, /host/)
    end

    it 'does not translate wrapper errors' do
      error = AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError.new('no writer')
      allow(AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient).to receive(:new).and_raise(error)

      expect { described_class.new_client(config) }.to raise_error(error)
    end
  end

  describe '#active?' do
    it 'is false once failover has failed, without asking the connection' do
      adapter = described_class.allocate
      adapter.instance_variable_set(:@connection_broken, true)

      expect(adapter.active?).to be false
    end
  end

  describe '#translate_exception' do
    let(:adapter) { described_class.allocate }
    let(:sql) { 'SELECT 1' }
    let(:binds) { [] }
    let(:message) { 'test error message' }

    it 'leaves an error that is not from the wrapper to the parent adapter' do
      exception = Trilogy::EOFError.new('eof')
      adapter.instance_variable_set(:@pool, nil)

      result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)

      expect(result).to be_a(ActiveRecord::ConnectionFailed)
    end

    # The wrapper reconnects the same connection object to a new physical connection, so the session
    # ActiveRecord configured on the old one has to be configured again, and anything it cached about
    # that connection forgotten.
    [AwsAdvancedRubyDriverWrapper::Errors::FailoverSuccessError,
     AwsAdvancedRubyDriverWrapper::Errors::TransactionStateUnknownError].each do |error_class|
      it "returns a #{error_class.name.split('::').last} unchanged, after reconfiguring the connection" do
        calls = []
        allow(adapter).to receive(:clear_cache!) { |**kwargs| calls << [:clear_cache!, kwargs] }
        allow(adapter).to receive(:configure_connection) { calls << [:configure_connection] }
        exception = error_class.new

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)

        expect(result).to eq(exception)
        expect(calls).to eq([[:clear_cache!, { new_connection: true }], [:configure_connection]])
      end
    end

    it 'turns a FailoverFailedError into a connection error and marks the connection broken' do
      adapter.instance_variable_set(:@pool, double('pool'))
      allow(adapter).to receive(:configure_connection)

      result = adapter.translate_exception(AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError.new(''),
                                           message: message, sql: sql, binds: binds)

      expect(result).to be_a(ActiveRecord::ConnectionFailed)
      expect(adapter.instance_variable_get(:@connection_broken)).to be true
      expect(adapter).not_to have_received(:configure_connection)
    end

    it 'returns any other wrapper error unchanged' do
      exception = AwsAdvancedRubyDriverWrapper::Errors::AwsError.new('generic aws error')
      allow(adapter).to receive(:configure_connection)

      expect(adapter.translate_exception(exception, message: message, sql: sql, binds: binds)).to eq(exception)
      expect(adapter).not_to have_received(:configure_connection)
    end
  end

  it 'is registered as the aws_trilogy adapter' do
    expect(ActiveRecord::ConnectionAdapters.resolve('aws_trilogy')).to eq(described_class)
  end

  describe '#adapter_name' do
    it 'reports the underlying Trilogy adapter name' do
      expect(described_class.allocate.adapter_name).to eq('Trilogy')
    end
  end

  describe 'MySQL type registry resolution' do
    # TrilogyAdapter registers :unsigned_integer under adapter: :trilogy; the wrapped adapter resolves
    # it through the :aws_trilogy -> :trilogy alias (type_adapter_alias.rb).
    it 'resolves a Trilogy type (:unsigned_integer) under aws_trilogy' do
      expect(ActiveRecord::Type.lookup(:unsigned_integer, adapter: :aws_trilogy))
        .to be_a(ActiveRecord::Type::UnsignedInteger)
    end
  end
end
