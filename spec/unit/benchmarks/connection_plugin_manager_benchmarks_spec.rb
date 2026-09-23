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
require_relative '../../../benchmarks/support/benchmark_plugin'
require_relative '../../../benchmarks/support/benchmark_services'

# Guards the assumptions the plugin manager benchmark relies on. The benchmark itself is not run in
# CI, so if the plugin contract or the service container shape drifts, these examples fail here
# instead of the benchmark silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Benchmarks do
    let(:plugin_count) { 10 }
    let(:plugin_codes) { Benchmarks::BenchmarkPlugin.register(plugin_count) }
    let(:props_with_plugins) { { wrapper_plugins: plugin_codes.join(',') } }
    let(:props_without_plugins) { { wrapper_plugins: '' } }
    let(:manager_with_plugins) do
      Services::PluginManager.new(Benchmarks::BenchmarkServices.container(props_with_plugins))
    end
    let(:manager_without_plugins) do
      Services::PluginManager.new(Benchmarks::BenchmarkServices.container(props_without_plugins))
    end
    let(:props_default_plugins) { { wrapper_plugins: 'initial_connection,failover' } }
    let(:manager_default_plugins) do
      Services::PluginManager.new(Benchmarks::BenchmarkServices.container(props_default_plugins))
    end
    let(:host_info) { Host::HostInfo.new(host: Benchmarks::BenchmarkServices::REALISTIC_HOST, port: '5432') }
    let(:stub_connection) { Benchmarks::BenchmarkServices::STUB_CONNECTION }

    describe Benchmarks::BenchmarkPlugin do
      it 'registers the requested number of distinct plugin codes' do
        expect(plugin_codes.uniq.length).to eq(plugin_count)
      end

      it 'builds a chain of the no-op plugins plus the terminal default plugin' do
        expect(manager_with_plugins.num_plugins).to eq(plugin_count + 1)
      end
    end

    describe 'the benchmarked pipelines' do
      it 'runs connect through the ten-plugin chain to the stubbed terminal connection' do
        expect(manager_with_plugins.connect(host_info, {}, false)).to be(stub_connection)
      end

      it 'runs internal_connect through the ten-plugin chain to the stubbed terminal connection' do
        expect(manager_with_plugins.internal_connect(host_info, {}, props_with_plugins, false)).to be(stub_connection)
      end

      it 'runs execute through the ten-plugin chain and returns the target callable result' do
        expect(manager_with_plugins.execute(RubyMethod::CONNECTION_QUERY, Object.new, -> { 42 })).to eq(42)
      end

      it 'runs the same pipelines with no plugins' do
        expect(manager_without_plugins.connect(host_info, {}, false)).to be(stub_connection)
        expect(manager_without_plugins.execute(RubyMethod::CONNECTION_QUERY, Object.new, -> { 42 })).to eq(42)
      end
    end

    describe 'the Default plugin series (real initial_connection + failover)' do
      it 'builds the initial_connection and failover chain plus the terminal default plugin' do
        expect(manager_default_plugins.num_plugins).to eq(3)
      end

      it 'runs connect through the default chain against the stubs' do
        expect(manager_default_plugins.connect(host_info, {}, false)).to be(stub_connection)
      end

      it 'runs execute through the default chain against the stubs' do
        expect(manager_default_plugins.execute(RubyMethod::CONNECTION_QUERY, stub_connection, -> { 42 })).to eq(42)
      end

      it 'runs internal_connect through the default chain against the stubs' do
        expect(manager_default_plugins.internal_connect(host_info, {}, props_default_plugins, false)).to be(stub_connection)
      end
    end
  end
end
