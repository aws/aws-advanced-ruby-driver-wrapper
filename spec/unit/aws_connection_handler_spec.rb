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
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_mysql2_adapter'

# Rails closes every pool and then drops the test database from a separate process (bin/rails test
# runs db:test:prepare as a child when the schema has changed). The wrapper's monitors keep their own
# connections to the database, so they have to stop when ActiveRecord closes everything.
RSpec.describe 'ActiveRecord::ConnectionAdapters::AwsConnectionHandler' do
  let(:handler) { ActiveRecord::ConnectionAdapters::ConnectionHandler.new }
  let(:monitor_service) { AwsAdvancedRubyDriverWrapper::Services::CoreServices.monitor_service }
  let(:storage) { AwsAdvancedRubyDriverWrapper::Services::CoreServices.storage_service }
  let(:topology) { AwsAdvancedRubyDriverWrapper::Host::RdsHostListProvider::TOPOLOGY_CACHE_NAME }
  let(:pool) { double('pool') }
  let(:calls) { [] }

  before do
    allow(pool).to receive(:disconnect!) { calls << :disconnect_pool }
    allow(monitor_service).to receive(:stop_and_remove_all) { calls << :stop_monitors }
  end

  it 'stops the wrapper monitors after clearing all connections' do
    allow(handler).to receive(:each_connection_pool).with(nil).and_return([pool])

    handler.clear_all_connections!

    expect(calls).to eq(%i[disconnect_pool stop_monitors])
  end

  it 'clears the cached topology so the next connection starts a new monitor' do
    storage.register(topology, ttl: 300)
    storage.set(topology, 'my-cluster', [:host])
    allow(handler).to receive(:each_connection_pool).with(nil).and_return([pool])

    handler.clear_all_connections!

    expect(storage.get(topology, 'my-cluster', register_access: false)).to be_nil
  end

  it 'does not fail when no wrapper connection has registered the topology cache' do
    allow(storage).to receive(:registered?).with(topology).and_return(false)
    allow(storage).to receive(:clear)
    allow(handler).to receive(:each_connection_pool).with(nil).and_return([pool])

    expect { handler.clear_all_connections! }.not_to raise_error
    expect(storage).not_to have_received(:clear)
  end

  it 'passes the role through to ActiveRecord' do
    allow(handler).to receive(:each_connection_pool).with(:all).and_return([pool])

    handler.clear_all_connections!(:all)

    expect(calls).to eq(%i[disconnect_pool stop_monitors])
  end

  it 'does not stop the monitors when only idle connections are flushed' do
    allow(handler).to receive(:each_connection_pool).and_return([])

    handler.flush_idle_connections!

    expect(monitor_service).not_to have_received(:stop_and_remove_all)
  end
end
