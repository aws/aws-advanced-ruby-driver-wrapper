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
require 'bigdecimal'
require 'date'
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/type_marker'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::TypeMarker do
  subject(:marker) { described_class }

  describe 'the marker values' do
    # These bytes are part of the stored format and are shared with the other AWS Advanced
    # Wrappers, so a change here would make already encrypted columns unreadable.
    it 'keeps the wire format values' do
      expect(
        [described_class::STRING, described_class::INTEGER, described_class::LONG, described_class::DOUBLE,
         described_class::FLOAT, described_class::BOOLEAN, described_class::BIG_DECIMAL, described_class::DATE,
         described_class::TIME, described_class::TIMESTAMP, described_class::LOCAL_DATE, described_class::LOCAL_TIME,
         described_class::LOCAL_DATE_TIME, described_class::BYTE_ARRAY, described_class::GENERIC]
      ).to eq([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 99])
    end

    it 'names every marker' do
      expect(described_class::ALL.map { |value| described_class::NAMES[value] }).to all(be_a(String))
    end

    it 'freezes its tables' do
      expect(described_class::NAMES).to be_frozen
      expect(described_class::ALL).to be_frozen
    end
  end

  describe '.from_value' do
    it 'returns the marker when it is known' do
      expect(marker.from_value(described_class::LONG)).to eq(described_class::LONG)
    end

    it 'raises for an unknown marker' do
      expect { marker.from_value(77) }.to raise_error(ArgumentError, /Unknown type marker: 77/)
    end

    it 'raises for nil' do
      expect { marker.from_value(nil) }.to raise_error(ArgumentError, /Unknown type marker: nil/)
    end
  end

  describe '.from_object' do
    it 'maps a UTF-8 string to STRING' do
      expect(marker.from_object('123-45-6789')).to eq(described_class::STRING)
    end

    it 'maps a binary string to BYTE_ARRAY' do
      expect(marker.from_object("\x00\x01\xff".b)).to eq(described_class::BYTE_ARRAY)
    end

    # Ruby has a single unbounded Integer type, so every integer is written as LONG.
    it 'maps an integer to LONG whatever its magnitude' do
      expect(marker.from_object(1)).to eq(described_class::LONG)
      expect(marker.from_object(2**40)).to eq(described_class::LONG)
    end

    it 'maps a float to DOUBLE' do
      expect(marker.from_object(1.5)).to eq(described_class::DOUBLE)
    end

    it 'maps booleans to BOOLEAN' do
      expect(marker.from_object(true)).to eq(described_class::BOOLEAN)
      expect(marker.from_object(false)).to eq(described_class::BOOLEAN)
    end

    it 'maps a BigDecimal to BIG_DECIMAL' do
      expect(marker.from_object(BigDecimal('1.5'))).to eq(described_class::BIG_DECIMAL)
    end

    it 'maps a Time to TIMESTAMP' do
      expect(marker.from_object(Time.now)).to eq(described_class::TIMESTAMP)
    end

    # DateTime is a subclass of Date, so the order of the checks matters.
    it 'maps a DateTime to LOCAL_DATE_TIME and a Date to LOCAL_DATE' do
      expect(marker.from_object(DateTime.new(2026, 8, 11, 12, 30, 45))).to eq(described_class::LOCAL_DATE_TIME)
      expect(marker.from_object(Date.new(2026, 8, 11))).to eq(described_class::LOCAL_DATE)
    end

    it 'falls back to GENERIC for anything else' do
      expect(marker.from_object(:pending)).to eq(described_class::GENERIC)
      expect(marker.from_object(nil)).to eq(described_class::GENERIC)
    end
  end

  describe '.name_for' do
    it 'returns the readable name' do
      expect(marker.name_for(described_class::BYTE_ARRAY)).to eq('BYTE_ARRAY')
    end

    it 'returns nil for an unknown marker' do
      expect(marker.name_for(77)).to be_nil
    end
  end

  describe '.known?' do
    it 'is true for a known marker' do
      expect(marker.known?(described_class::GENERIC)).to be(true)
    end

    it 'is false for an unknown marker' do
      expect(marker.known?(0)).to be(false)
    end
  end
end
