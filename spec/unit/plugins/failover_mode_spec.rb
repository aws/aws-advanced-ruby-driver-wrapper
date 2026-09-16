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
require 'aws_advanced_ruby_driver_wrapper/plugins/failover_mode'

RSpec.describe AwsAdvancedRubyDriverWrapper::Plugins::FailoverMode do
  describe '.from_value' do
    it 'returns nil for nil' do
      expect(described_class.from_value(nil)).to be_nil
    end

    it 'returns nil for an empty string' do
      expect(described_class.from_value('')).to be_nil
    end

    it 'returns nil for a whitespace-only string' do
      expect(described_class.from_value('   ')).to be_nil
      expect(described_class.from_value("\n")).to be_nil
      expect(described_class.from_value("\t \n")).to be_nil
    end

    it 'parses kebab-case, snake_case, and squashed spellings' do
      expect(described_class.from_value('strict-writer')).to eq(described_class::STRICT_WRITER)
      expect(described_class.from_value('strict_reader')).to eq(described_class::STRICT_READER)
      expect(described_class.from_value('readerorwriter')).to eq(described_class::READER_OR_WRITER)
    end

    it 'is case insensitive' do
      expect(described_class.from_value('STRICT_WRITER')).to eq(described_class::STRICT_WRITER)
      expect(described_class.from_value('Reader-Or-Writer')).to eq(described_class::READER_OR_WRITER)
    end

    it 'tolerates surrounding whitespace and newlines' do
      expect(described_class.from_value(' strict-reader ')).to eq(described_class::STRICT_READER)
      expect(described_class.from_value("strict_writer\n")).to eq(described_class::STRICT_WRITER)
      expect(described_class.from_value("\tReader_Or_Writer\n")).to eq(described_class::READER_OR_WRITER)
    end

    it 'accepts symbols' do
      expect(described_class.from_value(:strict_reader)).to eq(described_class::STRICT_READER)
    end

    it 'raises for an unknown value, echoing the original value' do
      expect { described_class.from_value('incorrect') }
        .to raise_error(ArgumentError, /Invalid failover mode: 'incorrect'/)
    end
  end
end
