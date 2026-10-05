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

require 'active_record/connection_adapters/mysql2_adapter'
require_relative '../mysql'
require_relative '../errors'
require_relative '../utils/ar_constants'

module ActiveRecord
  module ConnectionAdapters
    class AwsMysql2Adapter < Mysql2Adapter
      ADAPTER_NAME = 'AwsMySQL2'

      # ActiveRecord-only keys that should not be passed to the wrapper or native driver.
      AR_ONLY_KEYS = AwsAdvancedRubyDriverWrapper::Utils::AR_COMMON_KEYS

      def adapter_name = ADAPTER_NAME

      def self.new_client(config)
        AwsAdvancedRubyDriverWrapper::WrapperMysql2Client.new(**config.except(*AR_ONLY_KEYS))
      end

      def connect
        @connection_broken = false
        super
      end

      def reconnect
        @connection_broken = false
        super
      end

      def active?
        return false if @connection_broken

        super
      end

      def translate_exception(exception, message:, sql:, binds:)
        return super unless exception.is_a?(AwsAdvancedRubyDriverWrapper::Errors::AwsError)

        if exception.needs_reconfiguration
          # The wrapper has reconnected this connection object to a new physical connection, where the
          # statements prepared on the old one do not exist. Forget them so they are prepared again.
          clear_cache!(new_connection: true)
          configure_connection
          exception
        elsif exception.is_a?(AwsAdvancedRubyDriverWrapper::Errors::FailoverFailedError)
          @connection_broken = true
          ActiveRecord::ConnectionFailed.new(message, sql:, binds:, connection_pool: @pool)
        else
          exception
        end
      end
    end
  end
end

ActiveRecord::ConnectionAdapters.register(
  'aws_mysql2',
  'ActiveRecord::ConnectionAdapters::AwsMysql2Adapter',
  'aws_advanced_ruby_driver_wrapper/active_record/aws_mysql2_adapter'
)
