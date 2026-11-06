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
      when TestDriver::MYSQL2
        require 'mysql2'
        Mysql2::Client.new(**params)
      when TestDriver::TRILOGY
        require 'trilogy'
        Trilogy.new(**params)
      else
        raise "native_connect not implemented for driver: #{driver}"
      end
    end

    def self.wrapper_connect(driver, **params)
      case driver
      when TestDriver::PG
        require 'pg'
        AwsAdvancedRubyDriverWrapper::WrapperPgConnection.connect(**params)
      when TestDriver::MYSQL2
        require 'mysql2'
        AwsAdvancedRubyDriverWrapper::WrapperMysql2Client.new(**params)
      when TestDriver::TRILOGY
        require 'trilogy'
        AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient.new(**params)
      else
        raise "wrapper_connect not implemented for driver: #{driver}"
      end
    end

    def self.execute(driver, conn, sql)
      case driver
      when TestDriver::PG     then conn.exec(sql)
      when TestDriver::MYSQL2 then conn.query(sql)
      when TestDriver::TRILOGY then conn.query(sql).each_hash.to_a
      else raise "execute not implemented for driver: #{driver}"
      end
    end

    def self.close(driver, conn)
      case driver
      when TestDriver::PG                          then conn.finish
      when TestDriver::MYSQL2, TestDriver::TRILOGY then conn.close
      else raise "close not implemented for driver: #{driver}"
      end
    end

    def self.native_config(driver, host:, port:, user:, password:, dbname:)
      case driver
      when TestDriver::PG
        params = { host: host, dbname: dbname, user: user, password: password }
        params[:port] = port if port
        params
      when TestDriver::MYSQL2
        params = { host: host, database: dbname, username: user, password: password, ssl_mode: :required }
        params[:port] = port.to_i if port
        params
      when TestDriver::TRILOGY
        # trilogy expects ssl_mode as an integer constant, not the :required symbol mysql2 accepts.
        # 3 is TRILOGY_SSL_REQUIRED_NOVERIFY (encrypt, don't verify the server cert) - the same mode
        # the aws_trilogy ActiveRecord adapter maps :required to, and the noverify equivalent of the
        # mysql2/pg :required used elsewhere in the suite. Hard-coded to avoid loading trilogy here.
        params = { host: host, database: dbname, username: user, password: password,
                   ssl: true, ssl_mode: 3 }
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
      when TestDriver::MYSQL2, TestDriver::TRILOGY
        overrides[:username] = user     unless user == :__unset__
        overrides[:password] = password unless password == :__unset__
        overrides[:database] = dbname   unless dbname == :__unset__
      end
      config.merge(overrides)
    end

    # TLS options for an IAM (over-the-wire auth) connection, per driver. Centralised so the IAM
    # specs do not each repeat a `case drv` ssl block. Both MySQL-protocol drivers must enable the
    # cleartext plugin so the generated IAM token is sent via mysql_clear_password; trilogy only
    # sends it at all when the plugin is enabled, and mysql2 needs it for the same reason.
    #
    # Note native_config already sets a baseline ssl_mode per driver; these are the IAM-specific
    # additions callers merge on top of a native_config hash.
    def self.iam_tls_props(driver)
      case driver
      when TestDriver::PG
        { sslmode: 'require' }
      when TestDriver::MYSQL2
        { ssl_mode: :required, enable_cleartext_plugin: true }
      when TestDriver::TRILOGY
        # ssl_mode 3 is TRILOGY_SSL_REQUIRED_NOVERIFY (see native_config). Hard-coded so this helper
        # does not need to require 'trilogy' just to read the constant.
        { ssl: true, ssl_mode: 3, enable_cleartext_plugin: true }
      else
        {}
      end
    end
  end
end
