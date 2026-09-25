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

require 'aws_advanced_ruby_driver_wrapper/utils/sql_encoding'

RSpec.describe AwsAdvancedRubyDriverWrapper::Utils::SqlEncoding do
  describe '.inspectable' do
    it 'returns UTF-8 SQL as it is' do
      sql = "SELECT 'grün'"

      expect(described_class.inspectable(sql)).to equal(sql)
    end

    it 'returns ASCII SQL in an ASCII-compatible encoding as it is' do
      sql = 'SELECT 1'.encode(Encoding::US_ASCII)

      expect(described_class.inspectable(sql)).to equal(sql)
    end

    it 'converts SQL in an encoding that is not ASCII-compatible' do
      expect(described_class.inspectable("SELECT 'grün'".encode('UTF-16BE'))).to eq("SELECT 'grün'")
    end

    it 'converts non-ASCII SQL in an ASCII-compatible encoding' do
      expect(described_class.inspectable("SELECT 'grün'".encode('ISO-8859-1'))).to eq("SELECT 'grün'")
    end

    it 'replaces bytes that are invalid in UTF-8' do
      expect(described_class.inspectable("SELECT '\xFF'")).to eq("SELECT '�'")
    end

    it 'replaces bytes that are invalid in the encoding the SQL is in' do
      sql = "SELECT '\xFF\xFF'".dup.force_encoding(Encoding::SHIFT_JIS)

      expect(described_class.inspectable(sql)).to be_valid_encoding
    end

    it 'replaces bytes that have no character in UTF-8' do
      expect(described_class.inspectable("SELECT '\xFF'".b)).to eq("SELECT '�'")
    end

    it 'returns nil for SQL that has no converter to UTF-8' do
      expect(described_class.inspectable('SELECT 1'.dup.force_encoding(Encoding::UTF_7))).to be_nil
    end

    it 'returns anything that is not a String as it is' do
      expect(described_class.inspectable(nil)).to be_nil
      expect(described_class.inspectable(42)).to eq(42)
    end
  end
end
