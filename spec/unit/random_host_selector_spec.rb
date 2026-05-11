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
require 'aws_ruby_database_driver_wrapper/host/random_host_selector'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'
require 'aws_ruby_database_driver_wrapper/host/host_availability'

RSpec.describe AwsRubyDatabaseDriverWrapper::Host::RandomHostSelector do
  let(:selector) { described_class.new }

  let(:writer) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'writer-host',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER
    )
  end

  let(:reader1) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'reader-host-1',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::READER
    )
  end

  let(:reader2) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'reader-host-2',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::READER
    )
  end

  let(:unavailable_reader) do
    AwsRubyDatabaseDriverWrapper::Host::HostInfo.new(
      host: 'unavailable-reader',
      port: 5432,
      role: AwsRubyDatabaseDriverWrapper::Host::HostRole::READER,
      availability: AwsRubyDatabaseDriverWrapper::Host::HostAvailability::UNAVAILABLE
    )
  end

  describe '#select_host' do
    context 'when role is nil' do
      it 'returns a host from all available hosts' do
        hosts = [writer, reader1, reader2]
        result = selector.select_host(hosts, nil)
        expect(hosts).to include(result)
      end
    end

    context 'when filtering by reader role' do
      it 'returns only a reader host' do
        hosts = [writer, reader1, reader2]
        result = selector.select_host(hosts, AwsRubyDatabaseDriverWrapper::Host::HostRole::READER)
        expect(result).not_to be_nil
        expect(result.role).to eq(AwsRubyDatabaseDriverWrapper::Host::HostRole::READER)
      end
    end

    context 'when filtering by writer role' do
      it 'returns the writer host' do
        hosts = [writer, reader1, reader2]
        result = selector.select_host(hosts, AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER)
        expect(result).to eq(writer)
      end
    end

    context 'when no hosts match the requested role' do
      it 'returns nil' do
        hosts = [reader1, reader2]
        result = selector.select_host(hosts, AwsRubyDatabaseDriverWrapper::Host::HostRole::WRITER)
        expect(result).to be_nil
      end
    end

    context 'when hosts list is empty' do
      it 'returns nil' do
        result = selector.select_host([], AwsRubyDatabaseDriverWrapper::Host::HostRole::READER)
        expect(result).to be_nil
      end
    end

    context 'when hosts are unavailable' do
      it 'excludes unavailable hosts' do
        hosts = [unavailable_reader]
        result = selector.select_host(hosts, AwsRubyDatabaseDriverWrapper::Host::HostRole::READER)
        expect(result).to be_nil
      end

      it 'returns only available hosts when some are unavailable' do
        hosts = [unavailable_reader, reader1]
        result = selector.select_host(hosts, AwsRubyDatabaseDriverWrapper::Host::HostRole::READER)
        expect(result).to eq(reader1)
      end
    end
  end
end
