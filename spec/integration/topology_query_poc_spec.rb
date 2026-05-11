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

require 'aws_ruby_database_driver_wrapper/db_dialects/aurora_pg_dialect'
require 'aws_ruby_database_driver_wrapper/db_dialects/aurora_mysql_dialect'
require 'aws_ruby_database_driver_wrapper/host/host_availability'
require 'aws_ruby_database_driver_wrapper/host/host_availability_strategy'
require 'aws_ruby_database_driver_wrapper/host/host_info'
require 'aws_ruby_database_driver_wrapper/host/host_role'

RSpec.shared_examples 'Direct driver Aurora topology querying' do |driver_helper|
  include driver_helper

  it 'can process topology queries' do
    conn = driver_helper.native_connect
    # This should be replaced with actual db dialect detection in implementation.
    db_dialect = conn.instance_of?(Mysql2::Client) ?
                   AwsRubyDatabaseDriverWrapper::DbDialects::AuroraMysqlDialect.new :
                   AwsRubyDatabaseDriverWrapper::DbDialects::AuroraPgDialect.new
    result = db_dialect.execute(conn, db_dialect.class::TOPOLOGY_QUERY)
    hosts = result.map do |row|
      Host::HostInfo.new(
        host: "#{row['host_id']}.XYZ.region-west-1.rds.amazonaws.com",
        id: row['host_id'],
        role: [1, 't'].include?(row['is_writer']) ? Host::HostRole::WRITER : Host::HostRole::READER,
        availability: Host::HostAvailability::AVAILABLE,
        availability_strategy: Host::HostAvailabilityStrategy.new,
        last_update_time: row['last_update_time'] || Time.now
      )
    end

    hosts.each do |host|
      puts host
    end
  ensure
    conn&.close
  end
end

RSpec.describe 'Direct driver Aurora topology querying' do
  Host = AwsRubyDatabaseDriverWrapper::Host

  context 'PostgreSQL' do
    include_examples 'Direct driver Aurora topology querying', PgTestHelper
  end

  context 'MySQL' do
    include_examples 'Direct driver Aurora topology querying', MysqlTestHelper
  end
end
