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

# Guards the assumptions the SQL method analyzer benchmark relies on: that transaction_effect still
# exists with the shape the benchmark calls, and still classifies the sample statements the way the
# benchmark's case labels claim. The benchmark itself is not run in CI, so drift in the analyzer's
# API or behaviour fails here instead of the benchmark silently measuring the wrong thing.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Utils::SqlMethodAnalyzer do
    simple_select = 'SELECT id, name FROM users WHERE id = 42'
    commented_select = "-- pick a user\n/* by primary key */ SELECT id, name FROM users WHERE id = 42 -- trailing"
    multi_statement = "BEGIN; UPDATE users SET name = 'a' WHERE id = 1; UPDATE users SET name = 'b' WHERE id = 2; COMMIT"
    set_autocommit = 'SET AUTOCOMMIT = 1'

    execute_method = RubyMethod::STATEMENT_EXECUTE.name
    non_sql_method = RubyMethod::CONNECTION_PING.name
    close_method = RubyMethod::CONNECTION_CLOSE.name

    def effect(method_name, args)
      described_class.transaction_effect(method_name, args, autocommit: false, autocommit_before: false)
    end

    describe '.transaction_effect' do
      it 'short-circuits on a method that carries no SQL' do
        result = effect(non_sql_method, nil)
        expect(result.opens_transaction).to be(false)
        expect(result.closes_transaction).to be(false)
      end

      it 'treats a close call as closing via the method set alone' do
        expect(effect(close_method, nil).closes_transaction).to be(true)
      end

      it 'reports a plain statement as opening a transaction scope when autocommit is off' do
        expect(effect(execute_method, [simple_select]).opens_transaction).to be(true)
      end

      it 'reads through leading comments to the statement underneath' do
        expect(effect(execute_method, [commented_select]).opens_transaction).to be(true)
      end

      it 'reports a BEGIN-led batch as opening a transaction' do
        expect(effect(execute_method, [multi_statement]).opens_transaction).to be(true)
      end

      it 'reads the autocommit value out of a SET AUTOCOMMIT statement' do
        expect(effect(execute_method, [set_autocommit]).autocommit_value).to be(true)
      end

      it 'reports no autocommit change for a plain select' do
        expect(effect(execute_method, [simple_select]).autocommit_value).to be_nil
      end
    end
  end
end
