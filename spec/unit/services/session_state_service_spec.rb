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

require_relative '../../spec_helper'
require 'aws_advanced_ruby_driver_wrapper/services/session_state_service'

RSpec.describe AwsAdvancedRubyDriverWrapper::Services::SessionStateService do
  subject(:service) { described_class.new }

  describe '#initialize' do
    it 'defaults to not in transaction' do
      expect(service.in_transaction?).to be false
    end

    it 'defaults autocommit to true' do
      expect(service.autocommit?).to be true
    end
  end

  describe '#reset' do
    it 'resets state to defaults' do
      service.in_transaction = true
      service.autocommit = false
      service.reset
      expect(service.in_transaction?).to be false
      expect(service.autocommit?).to be true
    end
  end

  describe '#update_transaction_state' do
    let(:connection) { double('connection') }
    let(:dialect) { AwsAdvancedRubyDriverWrapper::DriverDialects::MysqlDriverDialect.new }

    it 'marks in_transaction on BEGIN' do
      service.update_transaction_state('connection.exec', ['BEGIN'], true, dialect, connection)
      expect(service.in_transaction?).to be true
    end

    it 'marks in_transaction on a BEGIN that is not UTF-8' do
      service.update_transaction_state('connection.exec', ['BEGIN'.encode('UTF-16LE')], true, dialect, connection)
      expect(service.in_transaction?).to be true
    end

    it 'does not raise on SQL with bytes that are invalid in its encoding' do
      expect { service.update_transaction_state('connection.exec', ["SELECT '\xFF'"], true, dialect, connection) }.not_to raise_error
    end

    it 'clears in_transaction on COMMIT' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['COMMIT'], true, dialect, connection)
      expect(service.in_transaction?).to be false
    end

    it 'clears in_transaction on ROLLBACK' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['ROLLBACK'], true, dialect, connection)
      expect(service.in_transaction?).to be false
    end

    it 'tracks SET AUTOCOMMIT = TRUE' do
      service.autocommit = false
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = TRUE'], false, dialect, connection)
      expect(service.autocommit?).to be true
    end

    it 'tracks SET AUTOCOMMIT = FALSE' do
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = FALSE'], true, dialect, connection)
      expect(service.autocommit?).to be false
    end

    it 'clears in_transaction when autocommit switches from false to true' do
      service.in_transaction = true
      service.autocommit = false
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = TRUE'], false, dialect, connection)
      expect(service.in_transaction?).to be false
    end

    it 'does not change state for non-SQL methods' do
      service.update_transaction_state('connection.close', [], true, dialect, connection)
      expect(service.in_transaction?).to be false
      expect(service.autocommit?).to be true
    end

    it 'does not open transaction on DML when autocommit is true' do
      service.update_transaction_state('connection.exec', ['SELECT 1'], true, dialect, connection)
      expect(service.in_transaction?).to be false
    end

    it 'opens transaction on DML when autocommit is false' do
      service.autocommit = false
      service.update_transaction_state('connection.exec', ['SELECT 1'], false, dialect, connection)
      expect(service.in_transaction?).to be true
    end

    it 'does not clear in_transaction when autocommit was already true before SET AUTOCOMMIT = TRUE' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = TRUE'], true, dialect, connection)
      expect(service.in_transaction?).to be true
    end

    it 'does not crash with empty args' do
      service.update_transaction_state('connection.exec', [], true, dialect, connection)
      expect(service.in_transaction?).to be false
      expect(service.autocommit?).to be true
    end

    it 'keeps in_transaction true when COMMIT raises (transaction outcome unknown)' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['COMMIT'], true, dialect, connection, succeeded: false)
      expect(service.in_transaction?).to be true
    end

    it 'closes transaction on connection.close' do
      service.in_transaction = true
      service.update_transaction_state('connection.close', [], true, dialect, connection)
      expect(service.in_transaction?).to be false
    end

    it 'closes transaction on connection.transaction' do
      service.in_transaction = true
      service.update_transaction_state('connection.transaction', [], true, dialect, connection)
      expect(service.in_transaction?).to be false
    end

    context 'when the dialect reports live transaction state' do
      let(:dialect) { double('dialect') }

      it 'uses true from the dialect even when SQL inference would say otherwise (e.g. COMMIT)' do
        service.in_transaction = true
        allow(dialect).to receive(:reported_in_transaction).and_return(true)
        service.update_transaction_state('connection.exec', ['COMMIT'], true, dialect, connection)
        expect(service.in_transaction?).to be true
      end

      it 'uses false from the dialect even when SQL inference would say otherwise (e.g. BEGIN)' do
        allow(dialect).to receive(:reported_in_transaction).and_return(false)
        service.update_transaction_state('connection.exec', ['BEGIN'], true, dialect, connection)
        expect(service.in_transaction?).to be false
      end

      it 'falls back to SQL inference when the dialect returns nil and the statement succeeded' do
        allow(dialect).to receive(:reported_in_transaction).and_return(nil)
        service.update_transaction_state('connection.exec', ['BEGIN'], true, dialect, connection)
        expect(service.in_transaction?).to be true
      end

      it 'leaves in_transaction unchanged when the dialect returns nil and the statement failed (e.g. failed BEGIN)' do
        allow(dialect).to receive(:reported_in_transaction).and_return(nil)
        service.update_transaction_state('connection.exec', ['BEGIN'], true, dialect, connection, succeeded: false)
        expect(service.in_transaction?).to be false
      end
    end
  end
end
