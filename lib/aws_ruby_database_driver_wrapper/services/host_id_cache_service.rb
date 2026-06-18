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

require_relative '../utils/rds_utils'
require_relative '../utils/rds_url_type'

module AwsRubyDatabaseDriverWrapper
  module Services
    class HostIdCacheService
      @cache = {}
      @mutex = Mutex.new

      class << self
        def clear_cache
          @mutex.synchronize { @cache.clear }
        end

        def get(host)
          @mutex.synchronize { @cache[host] }
        end

        def put(host, value)
          @mutex.synchronize { @cache[host] = value }
        end
      end

      def identify_connection(connection, connection_host_info, host_service, dialect_service)
        return nil if connection.nil? || connection_host_info.nil?

        url_type = Utils::RdsUtils.identify_rds_type(connection_host_info.host)

        case url_type
        when Utils::RdsUrlType::RDS_INSTANCE
          connection_host_info
        when Utils::RdsUrlType::IP_ADDRESS, Utils::RdsUrlType::OTHER
          get_cached_host_info(connection, connection_host_info, host_service, dialect_service)
        else
          basic_identify(connection, host_service, dialect_service)
        end
      end

      private

      def get_cached_host_info(connection, connection_host_info, host_service, dialect_service)
        host = connection_host_info.host
        id_and_name = self.class.get(host)

        unless id_and_name
          id_and_name = query_instance_id_and_name(connection, dialect_service)
          self.class.put(host, id_and_name)
        end

        instance_id, instance_name = id_and_name
        return nil if instance_id.nil? && instance_name.nil?

        find_host_in_topology(instance_id, instance_name, host_service)
      end

      def basic_identify(connection, host_service, dialect_service)
        id_and_name = query_instance_id_and_name(connection, dialect_service)
        return nil if id_and_name.nil?

        instance_id, instance_name = id_and_name
        return nil if instance_id.nil? && instance_name.nil?

        topology = host_service.host_list_provider&.refresh
        if topology.nil? || topology.empty?
          host_service.force_refresh_host_list
          topology = host_service.all_hosts
        end
        return nil if topology.nil? || topology.empty?

        topology.find { |h| h.id == instance_id || h.host == instance_name }
      end

      def find_host_in_topology(instance_id, instance_name, host_service)
        topology = host_service.all_hosts
        if topology.nil? || topology.empty?
          host_service.force_refresh_host_list
          topology = host_service.all_hosts
        end
        return nil if topology.nil? || topology.empty?

        topology.find { |h| h.id == instance_id || h.host == instance_name }
      end

      def query_instance_id_and_name(connection, dialect_service)
        dialect_service.db_dialect.instance_identity(connection)
      rescue StandardError
        [nil, nil]
      end
    end
  end
end
