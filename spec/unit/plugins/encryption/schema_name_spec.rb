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
require 'aws_ruby_database_driver_wrapper/plugins/kms_encryption/schema_name'

RSpec.describe AwsRubyDatabaseDriverWrapper::Plugins::Encryption::SchemaName do
  describe '.of' do
    it 'validates a string' do
      expect(described_class.of('encrypt').value).to eq('encrypt')
    end

    it 'accepts a symbol' do
      expect(described_class.of(:encrypt).value).to eq('encrypt')
    end

    it 'returns an existing schema name as it is' do
      existing = described_class.new('encrypt')
      expect(described_class.of(existing)).to be(existing)
    end
  end

  describe 'validation' do
    it 'accepts plain identifiers' do
      %w[encrypt Encrypt _private schema_2 a].each do |name|
        expect(described_class.new(name).value).to eq(name)
      end
    end

    it 'rejects an empty name' do
      expect { described_class.new('') }.to raise_error(ArgumentError, /cannot be empty/)
      expect { described_class.new('   ') }.to raise_error(ArgumentError, /cannot be empty/)
      expect { described_class.new(nil) }.to raise_error(ArgumentError, /cannot be empty/)
    end

    # Schema names are interpolated into the metadata queries, so anything that could end a
    # statement or start a new one has to be refused.
    it 'rejects anything that is not a plain identifier' do
      ['2schema', 'my schema', 'my-schema', '"quoted"', 'a.b', 'encrypt;DROP TABLE users',
       'encrypt--comment', "encrypt'", "encrypt\nDROP TABLE users", "encrypt\n"].each do |name|
        expect { described_class.new(name) }.to raise_error(ArgumentError, /Invalid schema name/)
      end
    end
  end

  describe 'string conversion' do
    subject(:schema) { described_class.new('encrypt') }

    it 'renders as the bare name' do
      expect(schema.to_s).to eq('encrypt')
    end

    it 'interpolates into SQL' do
      expect("SELECT 1 FROM #{schema}.key_storage").to eq('SELECT 1 FROM encrypt.key_storage')
    end

    it 'implicitly converts to a string' do
      expect(File.join(schema, 'x')).to eq('encrypt/x')
    end
  end

  describe 'equality' do
    it 'is equal to another schema name with the same value' do
      expect(described_class.new('encrypt')).to eq(described_class.new('encrypt'))
    end

    it 'is not equal to a different value' do
      expect(described_class.new('encrypt')).not_to eq(described_class.new('other'))
    end

    it 'is not equal to a bare string' do
      expect(described_class.new('encrypt')).not_to eq('encrypt')
    end

    it 'hashes by value, so it can be used as a hash key' do
      expect({ described_class.new('encrypt') => 1 }[described_class.new('encrypt')]).to eq(1)
    end
  end

  it 'is frozen' do
    schema = described_class.new('encrypt')
    expect(schema).to be_frozen
    expect(schema.value).to be_frozen
  end
end
