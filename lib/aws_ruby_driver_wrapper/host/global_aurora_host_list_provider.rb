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

require_relative 'rds_host_list_provider'
require_relative '../monitoring/global_cluster_topology_monitor'
require_relative '../property_definition'

module AwsRubyDriverWrapper
  module Host
    # Host list provider for Aurora Global Database clusters.
    # Extends RdsHostListProvider with multi-region instance templates
    # and uses GlobalClusterTopologyMonitor.
    class GlobalAuroraHostListProvider < RdsHostListProvider
      attr_reader :instance_templates_by_region

      def initialize(service_container:, topology_utils:)
        super
        @instance_templates_by_region = build_instance_templates_by_region
      end

      def force_refresh(verify_writer, timeout_sec)
        monitor = @service_container.monitor_service.run_if_absent(:cluster_topology, @cluster_id, @service_container) do |_sc|
          Monitoring::GlobalClusterTopologyMonitor.new(
            service_container: @service_container,
            cluster_id: @cluster_id,
            instance_template: @instance_template,
            instance_templates_by_region: @instance_templates_by_region,
            topology_utils: @topology_utils,
            monitoring_driver_props: @monitoring_driver_props,
            monitoring_wrapper_props: @monitoring_wrapper_props
          )
        end
        monitor.force_refresh(verify_writer, timeout_sec)
      rescue Timeout::Error
        nil
      end

      private

      def build_instance_templates_by_region
        props = @service_container.connection_service.wrapper_props
        patterns_str = PropertyDefinition::GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS.get(props)
        unless patterns_str
          raise Errors::AwsError,
                "#{PropertyDefinition::GLOBAL_CLUSTER_INSTANCE_HOST_PATTERNS.name} is required for Global Aurora Databases"
        end

        @topology_utils.parse_instance_templates(patterns_str, method(:validate_host_pattern!))
      end
    end
  end
end
