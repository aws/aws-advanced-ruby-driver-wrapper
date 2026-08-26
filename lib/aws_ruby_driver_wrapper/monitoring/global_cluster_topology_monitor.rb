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

require_relative 'cluster_topology_monitor'

module AwsRubyDriverWrapper
  module Monitoring
    # Topology monitor for Aurora Global Databases spanning multiple AWS regions.
    # Extends ClusterTopologyMonitor by using region-aware instance templates and
    # a global topology query that returns region information per instance.
    class GlobalClusterTopologyMonitor < ClusterTopologyMonitor
      # @param service_container [Services::ServiceContainer]
      # @param cluster_id [String]
      # @param instance_template [Host::HostInfo] default template (used for initial connection)
      # @param instance_templates_by_region [Hash{String => Host::HostInfo}] region -> instance template
      # @param topology_utils [Utils::GlobalAuroraTopologyUtils]
      # @param monitoring_driver_props [Hash]
      # @param monitoring_wrapper_props [Hash]
      def initialize(
        service_container:,
        cluster_id:,
        instance_template:,
        instance_templates_by_region:,
        topology_utils:,
        monitoring_driver_props:,
        monitoring_wrapper_props: {}
      )
        super(
          service_container:,
          cluster_id:,
          instance_template:,
          topology_utils:,
          monitoring_driver_props:,
          monitoring_wrapper_props:
        )
        @instance_templates_by_region = instance_templates_by_region
      end

      private

      def query_topology(conn)
        @topology_utils.query_global_topology(conn, initial_host_info, @instance_templates_by_region)
      end

      def resolve_instance_template(instance_id, conn)
        region = @topology_utils.query_region(instance_id, conn)
        return @instance_template if region.nil?

        template = @instance_templates_by_region[region]
        if template.nil?
          logger.warn("[#{@cluster_id}] No instance template for region '#{region}'")
          return @instance_template
        end

        template
      end
    end
  end
end
