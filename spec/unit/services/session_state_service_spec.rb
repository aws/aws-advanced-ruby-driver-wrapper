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
require 'aws_ruby_database_driver_wrapper/services/session_state_service'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::SessionStateService do
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
    it 'marks in_transaction on BEGIN' do
      service.update_transaction_state('connection.exec', ['BEGIN'], true)
      expect(service.in_transaction?).to be true
    end

    it 'clears in_transaction on COMMIT' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['COMMIT'], true)
      expect(service.in_transaction?).to be false
    end

    it 'clears in_transaction on ROLLBACK' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['ROLLBACK'], true)
      expect(service.in_transaction?).to be false
    end

    it 'tracks SET AUTOCOMMIT = TRUE' do
      service.autocommit = false
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = TRUE'], false)
      expect(service.autocommit?).to be true
    end

    it 'tracks SET AUTOCOMMIT = FALSE' do
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = FALSE'], true)
      expect(service.autocommit?).to be false
    end

    it 'clears in_transaction when autocommit switches from false to true' do
      service.in_transaction = true
      service.autocommit = false
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = TRUE'], false)
      expect(service.in_transaction?).to be false
    end

    it 'does not change state for non-SQL methods' do
      service.update_transaction_state('connection.close', [], true)
      expect(service.in_transaction?).to be false
      expect(service.autocommit?).to be true
    end

    it 'does not open transaction on DML when autocommit is true' do
      service.update_transaction_state('connection.exec', ['SELECT 1'], true)
      expect(service.in_transaction?).to be false
    end

    it 'opens transaction on DML when autocommit is false' do
      service.autocommit = false
      service.update_transaction_state('connection.exec', ['SELECT 1'], false)
      expect(service.in_transaction?).to be true
    end

    it 'does not clear in_transaction when autocommit was already true before SET AUTOCOMMIT = TRUE' do
      service.in_transaction = true
      service.update_transaction_state('connection.exec', ['SET AUTOCOMMIT = TRUE'], true)
      expect(service.in_transaction?).to be true
    end

    it 'does not crash with empty args' do
      service.update_transaction_state('connection.exec', [], true)
      expect(service.in_transaction?).to be false
      expect(service.autocommit?).to be true
    end

    it 'closes transaction on connection.close' do
      service.in_transaction = true
      service.update_transaction_state('connection.close', [], true)
      expect(service.in_transaction?).to be false
    end

    it 'closes transaction on connection.transaction' do
      service.in_transaction = true
      service.update_transaction_state('connection.transaction', [], true)
      expect(service.in_transaction?).to be false
    end
  end
end
