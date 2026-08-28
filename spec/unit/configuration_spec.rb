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

require 'rspec'
require 'aws_advanced_ruby_driver_wrapper'

RSpec.describe AwsAdvancedRubyDriverWrapper::Configuration do
  subject(:config) { described_class.new }

  after { AwsAdvancedRubyDriverWrapper.config.reset! }

  describe '#update' do
    it 'sets multiple keys at once' do
      handler = ->(_e) { true }
      init = ->(conn, host) {}

      config.update(custom_error_handler: handler, connection_init_func: init)

      expect(config.custom_error_handler).to eq(handler)
      expect(config.connection_init_func).to eq(init)
    end

    it 'raises ArgumentError for unknown keys' do
      expect { config.update(bogus: 'val') }.to raise_error(ArgumentError, /bogus/)
    end

    it 'returns self for chaining' do
      expect(config.update(custom_dialect: :foo)).to eq(config)
    end
  end

  describe '#reset!' do
    it 'clears all values to nil' do
      config.update(custom_dialect: :foo, connection_init_func: -> {})
      config.reset!

      expect(config.custom_dialect).to be_nil
      expect(config.connection_init_func).to be_nil
    end
  end

  describe '#prepare_host_func' do
    it 'delegates to RdsUtils' do
      func = lambda(&:upcase)
      config.prepare_host_func = func

      expect(AwsAdvancedRubyDriverWrapper::Utils::RdsUtils.prepare_host_func).to eq(func)
    end

    it 'reads from RdsUtils' do
      func = ->(host) { host }
      AwsAdvancedRubyDriverWrapper::Utils::RdsUtils.prepare_host_func = func

      expect(config.prepare_host_func).to eq(func)
    end

    it 'clears RdsUtils on reset' do
      config.prepare_host_func = ->(h) { h }
      config.reset!

      expect(AwsAdvancedRubyDriverWrapper::Utils::RdsUtils.prepare_host_func).to be_nil
    end
  end

  describe '#custom_dialect' do
    it 'stores and retrieves a custom dialect' do
      dialect = Object.new
      config.custom_dialect = dialect

      expect(config.custom_dialect).to eq(dialect)
    end
  end

  describe '#custom_error_handler' do
    it 'stores and retrieves a custom error handler' do
      handler = Object.new
      config.custom_error_handler = handler

      expect(config.custom_error_handler).to eq(handler)
    end
  end

  describe '#connection_init_func' do
    it 'stores and retrieves a callable' do
      func = ->(conn, host_info) {}
      config.connection_init_func = func

      expect(config.connection_init_func).to eq(func)
    end
  end
end

RSpec.describe AwsAdvancedRubyDriverWrapper do
  after { described_class.config.reset! }

  describe '.config' do
    it 'returns a Configuration instance' do
      expect(described_class.config).to be_a(AwsAdvancedRubyDriverWrapper::Configuration)
    end

    it 'returns the same instance on repeated calls' do
      expect(described_class.config).to equal(described_class.config)
    end
  end
end
