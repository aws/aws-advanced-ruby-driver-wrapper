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
#  limitations under the License.require 'rspec'

require 'aws_advanced_ruby_wrapper/db_dialects/mysql_dialect'
require 'aws_advanced_ruby_wrapper/host/host_info'

RSpec.describe AwsAdvancedRubyWrapper::DbDialects::MysqlDialect do
  subject(:dialect) { described_class.new }

  let(:connection) { instance_double('Mysql2::Client') }
  let(:host_info) { AwsAdvancedRubyWrapper::Host::HostInfo.new(host: 'db.example.com', port: 3306) }
  let(:config) { { database: 'testdb', username: 'user' } }

  describe '#default_port' do
    it 'returns correct port' do
      expect(dialect.default_port).to eq(3306)
    end
  end
end
