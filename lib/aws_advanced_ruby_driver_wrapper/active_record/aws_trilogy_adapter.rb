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

require 'active_record/connection_adapters/trilogy_adapter'
require_relative '../trilogy'
require_relative '../errors'
require_relative 'type_adapter_alias'
require_relative 'aws_connection_handler'

module ActiveRecord
  module ConnectionAdapters
    class AwsTrilogyAdapter < TrilogyAdapter
      # Connects as the parent adapter does, through the wrapper instead of trilogy itself: the ssl_mode
      # name is turned into the constant trilogy reads, and the whole config is passed on, since the
      # wrapper takes its own properties out and trilogy ignores the ActiveRecord-only keys.
      #
      # Translates connection errors the same way the parent adapter does, so ActiveRecord can tell a
      # missing database (which db:prepare creates) or rejected credentials from other failures.
      # Wrapper errors are not trilogy errors and pass through untranslated.
      def self.new_client(config)
        config[:ssl_mode] = parse_ssl_mode(config[:ssl_mode]) if config[:ssl_mode]
        AwsAdvancedRubyDriverWrapper::WrapperTrilogyClient.new(config)
      rescue ::Trilogy::Error => e
        raise translate_connect_error(config, e)
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
          # session ActiveRecord configured on the old one does not exist. Forget what was cached about
          # that connection and configure the new one.
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
  'aws_trilogy',
  'ActiveRecord::ConnectionAdapters::AwsTrilogyAdapter',
  'aws_advanced_ruby_driver_wrapper/active_record/aws_trilogy_adapter'
)
