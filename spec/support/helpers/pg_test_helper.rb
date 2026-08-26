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

module PgTestHelper
  def self.adapter_config
    {
      adapter: 'aws_postgresql',
      host: ENV.fetch('PG_HOST', nil),
      port: ENV.fetch('PG_PORT', 5432).to_i,
      username: ENV.fetch('PG_USERNAME', nil),
      password: ENV.fetch('PG_PASSWORD', nil),
      database: ENV.fetch('PG_DATABASE', nil)
    }
  end

  def self.native_config
    {
      host: ENV.fetch('PG_HOST', nil),
      port: ENV.fetch('PG_PORT', 5432).to_i,
      user: ENV.fetch('PG_USERNAME', nil),
      password: ENV.fetch('PG_PASSWORD', nil),
      dbname: ENV.fetch('PG_DATABASE', nil)
    }
  end

  def self.wrapper_connect
    AwsAdvancedRubyDriverWrapper::WrapperPgConnection.new(**native_config)
  end

  def self.native_connect
    PG::Connection.connect(**native_config)
  end

  def self.execute(conn, sql)
    conn.exec(sql)
  end

  def self.server_version(client)
    client.server_version
  end
end
