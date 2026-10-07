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

# Action Cable is not a dependency of this gem, so its PostgreSQL subscription adapter is replaced by a stand-in.
$LOAD_PATH.unshift(File.expand_path('../fixtures/action_cable_stub', __dir__))
require 'aws_advanced_ruby_driver_wrapper/active_record/aws_postgresql_adapter'

RSpec.describe 'Action Cable PostgreSQL subscription adapter with aws_postgresql' do
  # Action Cable runs its load hooks when its server loads.
  before(:all) { ActiveSupport.run_load_hooks(:action_cable, Object.new) }

  let(:adapter) { ActionCable::SubscriptionAdapter::PostgreSQL.new }

  it 'accepts the wrapper connection that aws_postgresql hands out as its raw connection' do
    expect { adapter.check(AwsAdvancedRubyDriverWrapper::WrapperPgConnection.allocate) }.not_to raise_error
  end

  it 'still rejects connections that are not PostgreSQL' do
    expect { adapter.check(Object.new) }.to raise_error(RuntimeError, /must be PostgreSQL/)
  end
end
