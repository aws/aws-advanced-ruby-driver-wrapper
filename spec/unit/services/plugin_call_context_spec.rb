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
require 'aws_ruby_database_driver_wrapper/services/plugin_call_context'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::PluginCallContext do
  let(:block) { proc { |row| row } }
  subject(:context) { described_class.new('SELECT 1', ['SELECT 1', []], block) }

  it 'carries the SQL, the arguments and the block of the call' do
    expect(context.sql).to eq('SELECT 1')
    expect(context.args).to eq(['SELECT 1', []])
    expect(context.block).to be(block)
  end

  it 'has no block when the call was made without one' do
    expect(described_class.new('SELECT 1', []).block).to be_nil
  end

  it 'has no SQL when the caller could not say what it was' do
    expect(described_class.new(nil, []).sql).to be_nil
  end

  # A plugin that has to change what the driver is called with replaces these rather than
  # modifying what it was handed, which is the application's own array.
  it 'lets the arguments and the block be replaced' do
    other_block = proc { |row| row }
    context.args = %w[replaced]
    context.block = other_block

    expect(context.args).to eq(%w[replaced])
    expect(context.block).to be(other_block)
  end

  # The SQL is what the call was made with; nothing downstream is allowed to rewrite it.
  it 'does not let the SQL be replaced' do
    expect(context).not_to respond_to(:sql=)
  end
end
