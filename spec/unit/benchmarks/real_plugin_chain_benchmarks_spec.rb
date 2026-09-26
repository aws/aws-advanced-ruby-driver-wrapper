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

# Offline AWS credentials so the auth plugins resolve statically at construction, matching the
# benchmark. Set before the support files (and the gem) load.
ENV['AWS_ACCESS_KEY_ID'] ||= 'AKIAFAKEFAKEFAKEFAKE'
ENV['AWS_SECRET_ACCESS_KEY'] ||= 'fakefakefakefakefakefakefakefakefakefake'
ENV['AWS_REGION'] ||= 'us-east-1'

require_relative '../../spec_helper'
require_relative '../../../benchmarks/support/real_plugin_chain_support'

# Guards the assumptions the real-plugin-chain benchmark relies on: that a manager can be built for
# each wrapper plugin (and the default combo) and driven through the execute pipeline, returning the
# target result. The benchmark is not run in CI, so if a plugin's construction or its execute path
# drifts, that surfaces here instead of the benchmark silently breaking.
module AwsAdvancedRubyDriverWrapper
  RSpec.describe Benchmarks::RealPluginChainSupport do
    let(:storage_services) { [] }

    after do
      storage_services.each(&:shutdown)
      described_class.release_providers
    end

    def build(plugin_codes)
      described_class.build_manager(plugin_codes, storage_services)
    end

    describe '.build_manager' do
      it 'wires the manager back onto its own container so kms_encryption can reach the call context' do
        manager = build('kms_encryption')
        expect(manager).to be_a(Services::PluginManager)
      end

      it 'registers one StorageService per manager for later shutdown' do
        build('iam')
        build('secrets_manager')
        expect(storage_services.length).to eq(2)
        expect(storage_services).to all(be_a(Utils::Storage::StorageService))
      end
    end

    describe 'the benchmarked execute pipeline' do
      described_class::CHAINS.each do |name, plugin_codes|
        it "builds the '#{name}' chain and runs execute to the target result" do
          manager = build(plugin_codes)
          expect(described_class.run_execute(manager)).to eq(1)
        end
      end
    end

    describe 'the plugins that subscribe only to connect' do
      # These are loaded into the manager but subscribe only to connect (and internal_connect), so on
      # the execute pipeline they are pass-throughs: execute still returns the target result and only
      # the terminal default plugin does any work, which is why they benchmark the same as no_plugins.
      %w[iam secrets_manager initial_connection].each do |plugin_code|
        it "loads '#{plugin_code}' but keeps it off the execute path" do
          manager = build(plugin_code)
          baseline = build('')
          expect(manager.num_plugins).to eq(baseline.num_plugins + 1)
          expect(described_class.run_execute(manager)).to eq(1)
        end
      end
    end
  end
end
