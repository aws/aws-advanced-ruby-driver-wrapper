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
require 'aws_advanced_ruby_driver_wrapper/mysql'
require_relative '../../../benchmarks/support/benchmark_services'
require_relative '../../../benchmarks/support/fake_mysql2_driver'

# Guards the assumptions the wrapper overhead benchmark relies on: that a wrapper client can be built
# over the fake driver and driven through the plugin-free pipeline the way the benchmark does. The
# benchmark itself is not run in CI, so drift in the client's construction or the fake driver's shape
# fails here instead of the benchmark silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Benchmarks::FakeMysql2Driver do
    def build_wrapped_client(fake_connection)
      container = Benchmarks::BenchmarkServices.container({ wrapper_plugins: '' }, current_connection: fake_connection)
      container.plugin_manager = Services::PluginManager.new(container)

      client = Mysql2WrapperClient.allocate
      client.instance_variable_set(:@service_container, container)
      client.instance_variable_set(:@async_conn, nil)
      client.instance_variable_set(:@async_sql, nil)
      client.instance_variable_set(:@last_sql, nil)
      client
    end

    let(:sql) { 'SELECT id, name FROM users WHERE id = 42' }
    let(:raw_client) { Benchmarks::FakeMysql2Driver::FakeClient.new(row_count: 3) }
    let(:wrapped_client) { build_wrapped_client(raw_client) }

    it 'wraps query results so they iterate through the pipeline' do
      result = wrapped_client.query(sql)
      expect(result).to be_a(Mysql2WrapperResult)

      rows = []
      result.each { |row| rows << row } # rubocop:disable Style/MapIntoArray -- exercising the wrapped #each
      expect(rows.length).to eq(3)
      expect(rows.first['id']).to eq(42)
    end

    it 'returns a wrapped statement from prepare' do
      expect(wrapped_client.prepare(sql)).to be_a(Mysql2WrapperStatement)
    end

    it 'forwards escape and ping through the pipeline to the fake driver' do
      expect(wrapped_client.escape(sql)).to eq(sql)
      expect(wrapped_client.ping).to be(true)
    end

    it 'produces the same rows raw and wrapped, for a fair pair' do
      raw_ids = raw_client.query(sql).map { |row| row['id'] }
      wrapped_ids = wrapped_client.query(sql).map { |row| row['id'] }
      expect(wrapped_ids).to eq(raw_ids)
    end
  end
end
