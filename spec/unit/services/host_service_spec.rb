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
require 'aws_ruby_database_driver_wrapper/services/host_service'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'
require 'aws_ruby_database_driver_wrapper/host/random_host_selector'
require 'aws_ruby_database_driver_wrapper/errors'

RSpec.describe AwsRubyDatabaseDriverWrapper::Services::HostService do
  let(:service) { described_class.new }

  let(:reader) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'reader-host',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::READER
    )
  end

  let(:hosts) { [reader] }

  describe '#select_host' do
    context 'with a default strategy' do
      it 'delegates to the registered selector' do
        result = service.select_host(hosts, AwsRubyDatabaseDriverWrapper::Host::HostRole::READER, 'random')
        expect(result).to eq(reader)
      end
    end

    context 'with an unknown strategy' do
      it 'raises an error' do
        expect { service.select_host(hosts, nil, 'nonexistent') }
          .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Unsupported host selection strategy/)
      end
    end
  end

  describe '#register_host_selector' do
    it 'makes a new strategy available for selection' do
      custom_selector = instance_double('CustomSelector')
      allow(custom_selector).to receive(:select_host).and_return(reader)

      service.register_host_selector('custom', custom_selector)
      result = service.select_host(hosts, nil, 'custom')

      expect(result).to eq(reader)
    end

    it 'raises an error when overriding a default strategy' do
      custom_selector = instance_double('CustomSelector')

      expect { service.register_host_selector('random', custom_selector) }
        .to raise_error(AwsRubyDatabaseDriverWrapper::Errors::AwsError, /Cannot override default host selection strategy/)
    end
  end
end
