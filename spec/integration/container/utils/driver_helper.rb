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

require_relative 'test_driver'
require_relative 'test_environment'

module Integration
  module DriverHelper
    def self.native_connect(driver, **params)
      case driver
      when TestDriver::PG
        require 'pg'
        PG.connect(**params)
      when TestDriver::MYSQL
        require 'mysql2'
        Mysql2::Client.new(**params)
      else
        raise "native_connect not implemented for driver: #{driver}"
      end
    end

    def self.wrapper_connect(driver, **params)
      case driver
      when TestDriver::PG
        require 'pg'
        AwsAdvancedRubyDriverWrapper::WrapperPgConnection.connect(**params)
      when TestDriver::MYSQL
        require 'mysql2'
        AwsAdvancedRubyDriverWrapper::WrapperMysql2Client.new(**params)
      else
        raise "wrapper_connect not implemented for driver: #{driver}"
      end
    end

    def self.execute(driver, conn, sql)
      case driver
      when TestDriver::PG    then conn.exec(sql)
      when TestDriver::MYSQL then conn.query(sql)
      else raise "execute not implemented for driver: #{driver}"
      end
    end

    def self.close(driver, conn)
      case driver
      when TestDriver::PG    then conn.finish
      when TestDriver::MYSQL then conn.close
      else raise "close not implemented for driver: #{driver}"
      end
    end

    def self.native_config(driver, host:, port:, user:, password:, dbname:)
      case driver
      when TestDriver::PG
        params = { host: host, dbname: dbname, user: user, password: password }
        params[:port] = port if port
        params
      when TestDriver::MYSQL
        params = { host: host, database: dbname, username: user, password: password, ssl_mode: :required }
        params[:port] = port.to_i if port
        params
      else
        raise "native_config not implemented for driver: #{driver}"
      end
    end

    def self.override_config(driver, config, user: :__unset__, password: :__unset__, dbname: :__unset__)
      overrides = {}
      case driver
      when TestDriver::PG
        overrides[:user] = user unless user == :__unset__
        overrides[:password] = password unless password == :__unset__
        overrides[:dbname] = dbname unless dbname == :__unset__
      when TestDriver::MYSQL
        overrides[:username] = user     unless user == :__unset__
        overrides[:password] = password unless password == :__unset__
        overrides[:database] = dbname   unless dbname == :__unset__
      end
      config.merge(overrides)
    end
  end
end
