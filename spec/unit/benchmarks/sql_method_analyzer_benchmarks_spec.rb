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

# Guards the assumptions the SQL method analyzer benchmark relies on: that each analyzer method the
# benchmark drives still exists with the shape it calls, and still classifies the sample statements
# the way the benchmark's case labels claim. The benchmark itself is not run in CI, so drift in the
# analyzer's API or behaviour fails here instead of the benchmark silently measuring the wrong thing.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Utils::SqlMethodAnalyzer do
    simple_select = 'SELECT id, name FROM users WHERE id = 42'
    commented_select = "-- pick a user\n/* by primary key */ SELECT id, name FROM users WHERE id = 42 -- trailing"
    multi_statement = "BEGIN; UPDATE users SET name = 'a' WHERE id = 1; UPDATE users SET name = 'b' WHERE id = 2; COMMIT"
    set_autocommit = 'SET AUTOCOMMIT = 1'

    execute_method = RubyMethod::STATEMENT_EXECUTE.name
    non_sql_method = RubyMethod::CONNECTION_PING.name
    close_method = RubyMethod::CONNECTION_CLOSE.name

    describe '.opens_transaction?' do
      it 'short-circuits on a method that carries no SQL' do
        expect(described_class.opens_transaction?(non_sql_method, nil, autocommit: true)).to be(false)
      end

      it 'reports a plain statement as opening a transaction scope when autocommit is off' do
        expect(described_class.opens_transaction?(execute_method, [simple_select], autocommit: false)).to be(true)
      end

      it 'reads through leading comments to the statement underneath' do
        expect(described_class.opens_transaction?(execute_method, [commented_select], autocommit: false)).to be(true)
      end

      it 'reports a BEGIN-led batch as opening a transaction' do
        expect(described_class.opens_transaction?(execute_method, [multi_statement], autocommit: false)).to be(true)
      end
    end

    describe '.closes_transaction?' do
      it 'short-circuits on a method that carries no SQL' do
        expect(described_class.closes_transaction?(non_sql_method, nil)).to be(false)
      end

      it 'reports a plain select as not closing a transaction' do
        expect(described_class.closes_transaction?(execute_method, [simple_select])).to be(false)
      end

      it 'treats a close call as closing a transaction via the method set alone' do
        expect(described_class.closes_transaction?(close_method, nil)).to be(true)
      end
    end

    describe 'the autocommit false->true switch the benchmark reconstructs' do
      def switches?(method_name, args)
        described_class.sets_autocommit?(method_name, args) && described_class.autocommit_value(args) == true
      end

      it 'is false for a plain select' do
        expect(switches?(execute_method, [simple_select])).to be(false)
      end

      it 'is true for SET AUTOCOMMIT = 1' do
        expect(switches?(execute_method, [set_autocommit])).to be(true)
      end
    end

    describe '.sets_autocommit?' do
      it 'is true for a SET AUTOCOMMIT statement' do
        expect(described_class.sets_autocommit?(execute_method, [set_autocommit])).to be(true)
      end

      it 'is false for a plain select' do
        expect(described_class.sets_autocommit?(execute_method, [simple_select])).to be(false)
      end
    end

    describe '.autocommit_value' do
      it 'reads the target value out of the statement' do
        expect(described_class.autocommit_value([set_autocommit])).to be(true)
      end
    end
  end
end
