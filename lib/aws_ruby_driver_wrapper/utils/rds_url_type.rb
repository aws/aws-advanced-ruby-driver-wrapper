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

module AwsRubyDriverWrapper
  module Utils
    # Enumeration of RDS/Aurora endpoint URL types with classification attributes.
    class RdsUrlType
      attr_reader :name

      def initialize(name, rds:, rds_cluster:, has_region:)
        @name = name
        @rds = rds
        @rds_cluster = rds_cluster
        @has_region = has_region
        freeze
      end

      def rds?
        @rds
      end

      def rds_cluster?
        @rds_cluster
      end

      def region?
        @has_region
      end

      def to_s
        @name.to_s
      end

      private_class_method :new

      IP_ADDRESS =
        new(:ip_address, rds: false, rds_cluster: false, has_region: false)
      RDS_WRITER_CLUSTER =
        new(:rds_writer_cluster, rds: true,  rds_cluster: true, has_region: true)
      RDS_READER_CLUSTER =
        new(:rds_reader_cluster, rds: true,  rds_cluster: true, has_region: true)
      RDS_CUSTOM_CLUSTER =
        new(:rds_custom_cluster, rds: true,  rds_cluster: true, has_region: true)
      RDS_PROXY =
        new(:rds_proxy, rds: true, rds_cluster: false, has_region: true)
      RDS_PROXY_ENDPOINT =
        new(:rds_proxy_endpoint, rds: true, rds_cluster: false, has_region: true)
      RDS_INSTANCE =
        new(:rds_instance, rds: true, rds_cluster: false, has_region: true)
      RDS_AURORA_LIMITLESS_DB_SHARD_GROUP =
        new(:rds_aurora_limitless_db_shard_group, rds: true, rds_cluster: false, has_region: true)
      RDS_GLOBAL_WRITER_CLUSTER =
        new(:rds_global_writer_cluster, rds: true, rds_cluster: true, has_region: false)
      OTHER =
        new(:other, rds: false, rds_cluster: false, has_region: false)
    end
  end
end
