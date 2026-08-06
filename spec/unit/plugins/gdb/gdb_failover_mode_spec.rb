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

require_relative '../../../spec_helper'
require 'aws_ruby_database_driver_wrapper/plugins/gdb/gdb_failover_mode'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Gdb::GdbFailoverMode do
  describe '.from_value' do
    it 'returns nil for nil' do
      expect(described_class.from_value(nil)).to be_nil
    end

    it 'returns nil for an empty string' do
      expect(described_class.from_value('')).to be_nil
    end

    it 'parses kebab-case values' do
      expect(described_class.from_value('strict-writer')).to eq(described_class::STRICT_WRITER)
      expect(described_class.from_value('strict-home-reader')).to eq(described_class::STRICT_HOME_READER)
      expect(described_class.from_value('strict-out-of-home-reader')).to eq(described_class::STRICT_OUT_OF_HOME_READER)
      expect(described_class.from_value('strict-any-reader')).to eq(described_class::STRICT_ANY_READER)
      expect(described_class.from_value('home-reader-or-writer')).to eq(described_class::HOME_READER_OR_WRITER)
      expect(described_class.from_value('out-of-home-reader-or-writer')).to eq(described_class::OUT_OF_HOME_READER_OR_WRITER)
      expect(described_class.from_value('any-reader-or-writer')).to eq(described_class::ANY_READER_OR_WRITER)
    end

    it 'parses snake_case values' do
      expect(described_class.from_value('strict_out_of_home_reader')).to eq(described_class::STRICT_OUT_OF_HOME_READER)
      expect(described_class.from_value('home_reader_or_writer')).to eq(described_class::HOME_READER_OR_WRITER)
    end

    it 'parses squashed values' do
      expect(described_class.from_value('strictanyreader')).to eq(described_class::STRICT_ANY_READER)
      expect(described_class.from_value('anyreaderorwriter')).to eq(described_class::ANY_READER_OR_WRITER)
    end

    it 'is case insensitive' do
      expect(described_class.from_value('STRICT_WRITER')).to eq(described_class::STRICT_WRITER)
      expect(described_class.from_value('Home_Reader_Or_Writer')).to eq(described_class::HOME_READER_OR_WRITER)
    end

    it 'accepts symbols' do
      expect(described_class.from_value(:strict_home_reader)).to eq(described_class::STRICT_HOME_READER)
    end

    it 'raises for an unknown value' do
      expect { described_class.from_value('strict_nonsense') }
        .to raise_error(ArgumentError, /Invalid global database failover mode: 'strict_nonsense'/)
    end

    it 'round-trips every mode constant' do
      described_class::ALL.each do |mode|
        expect(described_class.from_value(mode.to_s)).to eq(mode)
      end
    end
  end
end
