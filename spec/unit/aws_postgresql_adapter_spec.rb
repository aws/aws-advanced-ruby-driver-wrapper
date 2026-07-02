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
require 'aws_ruby_database_driver_wrapper/active_record/aws_postgresql_adapter'
require 'aws_ruby_database_driver_wrapper/errors'

RSpec.describe ActiveRecord::ConnectionAdapters::AwsPostgreSQLAdapter do
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
      it 'returns the original exception and sets needs_reconfiguration' do
        exception = AwsRubyDatabaseDriverWrapper::Errors::FailoverSuccessError.new

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to eq(exception)
        expect(adapter.instance_variable_get(:@needs_reconfiguration)).to be true
      end
    end

    context 'when exception is a FailoverFailedError' do
      it 'returns a connection error and sets connection_broken' do
        exception = AwsRubyDatabaseDriverWrapper::Errors::FailoverFailedError.new('')
        pool = double('pool')
        adapter.instance_variable_set(:@pool, pool)

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to be_a(ActiveRecord::ConnectionFailed)
        expect(adapter.instance_variable_get(:@connection_broken)).to be true
      end
    end

    context 'when exception is a generic AwsError' do
      it 'returns the original exception unchanged' do
        exception = AwsRubyDatabaseDriverWrapper::Errors::AwsError.new('generic aws error')

        result = adapter.translate_exception(exception, message: message, sql: sql, binds: binds)
        expect(result).to eq(exception)
      end
    end
  end
end
