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

require_relative '../host/host_role'
require_relative '../host/host_availability'
require_relative '../logging'

module AwsRubyDatabaseDriverWrapper
  module Utils
    class RetryUtil
      include Logging

      SHORT_DELAY_SEC = 0.1

      WriterResult = Data.define(:connection, :host_info)

      def initialize(service_container)
        @host_service = service_container.host_service
        @dialect_service = service_container.dialect_service
        @connection_service = service_container.connection_service
      end

      def connect_to_writer(plugin_to_skip, plugin_manager, deadline:)
        loop do
          break if Time.now >= deadline

          @host_service.refresh_host_list
          hosts = @host_service.all_hosts
          writer_candidate = hosts.find { |h| h.role == Host::HostRole::WRITER }

          if writer_candidate.nil?
            logger.debug { 'No writer host found in topology' }
            sleep(SHORT_DELAY_SEC)
            next
          end

          allowed_hosts = @host_service.hosts
          unless allowed_hosts.any? { |h| h.host_and_port == writer_candidate.host_and_port }
            logger.debug { "New writer not in allowed hosts: #{writer_candidate.url}" }
            sleep(SHORT_DELAY_SEC)
            next
          end

          success = false
          while Time.now < deadline
            begin
              candidate_conn = plugin_manager.connect(writer_candidate, @connection_service.driver_props, false,
                                                      plugin_to_skip: plugin_to_skip)
              role = @dialect_service.db_dialect.host_role(candidate_conn)
              if role == Host::HostRole::WRITER
                result = WriterResult.new(candidate_conn, writer_candidate.deep_dup.tap { |h| h.role = role })
                success = true
                return result
              end
            rescue StandardError => e
              logger.debug { "Exception connecting to writer #{writer_candidate.host}: #{e.message}" }
            end

            close_quietly(candidate_conn) unless success
          end
        end

        raise Timeout::Error, 'Timed out waiting for a writer connection'
      end

      private

      def close_quietly(conn)
        return if conn.nil?

        @dialect_service.driver_dialect.close_connection(conn)
      rescue StandardError
        # ignore
      end
    end
  end
end
