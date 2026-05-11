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

require_relative '../support/shared_contexts/adapter_context'

RSpec.shared_examples 'ActiveRecord adapter failover handling' do |driver_helper|
  include driver_helper

  it 'correctly handles FailoverFailed' do
    ActiveRecord::Base.establish_connection(driver_helper.adapter_config)

    expect do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        expect(ActiveRecord::Base.connection_pool.connections.count(&:in_use?)).to eq(1)
        conn.execute('SIMULATE FAILOVER_FAILED')
      end
    end.to raise_error(ActiveRecord::ConnectionFailed)

    # NOTE: the broken connection is lazily removed, so it won't be removed until we try to grab a connection from
    # the pool again.

    ActiveRecord::Base.connection_pool.with_connection do |conn|
      conn.execute('SELECT 1 AS test')
    end
  end

  it 'correctly handles FailoverSuccess' do
    ActiveRecord::Base.establish_connection(driver_helper.adapter_config)

    expect do
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        expect(ActiveRecord::Base.connection_pool.connections.count(&:in_use?)).to eq(1)
        conn.execute('SIMULATE FAILOVER_SUCCESS')
      end
    end.to raise_error(AwsAdvancedRubyWrapper::Errors::FailoverSuccessError)

    # NOTE: the broken connection is lazily removed, so it won't be removed until we try to grab a connection from
    # the pool again.

    ActiveRecord::Base.connection_pool.with_connection do |conn|
      conn.execute('SELECT 1 AS test')
    end
  end
end

RSpec.describe 'ActiveRecord adapter failover handling' do
  include_context 'adapter context'

  context 'PostgreSQL' do
    include_examples 'ActiveRecord adapter failover handling', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'ActiveRecord adapter failover handling', MysqlTestHelper
  end
end
