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

require_relative 'pg_dialect'
require_relative 'utils/dialect_utils'

module AwsRubyDriverWrapper
  module DbDialects
    class MultiAzClusterPgDialect < PgDialect
      IS_RDS_CLUSTER_QUERY = <<~SQL
        SELECT multi_az_db_cluster_source_dbi_resource_id FROM rds_tools.multi_az_db_cluster_source_dbi_resource_id()
      SQL

      TOPOLOGY_QUERY = <<~SQL.freeze
        SELECT id AS instance_id, endpoint AS endpoint FROM rds_tools.show_topology('aws_ruby_driver_wrapper-#{AwsRubyDriverWrapper::VERSION}')
      SQL

      INSTANCE_IDENTITY_QUERY = <<~SQL
        SELECT id AS instance_id,
        SUBSTRING(endpoint FROM 0 FOR POSITION('.' IN endpoint)) AS instance_name
        FROM rds_tools.show_topology()
        WHERE id OPERATOR(pg_catalog.=) rds_tools.dbi_resource_id()
      SQL

      WRITER_ID_QUERY = <<~SQL
        SELECT multi_az_db_cluster_source_dbi_resource_id FROM rds_tools.multi_az_db_cluster_source_dbi_resource_id()
        WHERE multi_az_db_cluster_source_dbi_resource_id OPERATOR(pg_catalog.!=)
        (SELECT dbi_resource_id FROM rds_tools.dbi_resource_id())
      SQL

      WRITER_ID_QUERY_COLUMN_NAME = 'multi_az_db_cluster_source_dbi_resource_id'

      def dialect?(connection)
        result = @driver_dialect.execute(connection, IS_RDS_CLUSTER_QUERY)
        return false unless result.any?

        row = result.first
        !row['multi_az_db_cluster_source_dbi_resource_id'].nil?
      rescue StandardError
        false
      end

      def dialect_update_candidates
        []
      end

      def topology_query
        TOPOLOGY_QUERY
      end

      def instance_identity(connection)
        query_instance_identity(@driver_dialect, connection, INSTANCE_IDENTITY_QUERY)
      end

      def writer_id_query
        WRITER_ID_QUERY
      end

      def writer_id_column_name
        WRITER_ID_QUERY_COLUMN_NAME
      end

      # @param service_container [Services::ServiceContainer]
      # @return [Host::RdsHostListProvider] the host list provider
      def create_host_list_provider(service_container)
        require_relative '../utils/multi_az_topology_utils'
        require_relative '../host/rds_host_list_provider'
        topology_utils = Utils::MultiAzTopologyUtils.new(dialect: self)
        Host::RdsHostListProvider.new(service_container:, topology_utils:)
      end
    end
  end
end
