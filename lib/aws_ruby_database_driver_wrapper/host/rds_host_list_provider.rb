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

require 'concurrent'
require_relative '../logging'
require_relative '../errors'
require_relative '../property_definition'
require_relative '../utils/rds_utils'
require_relative '../utils/rds_url_type'
require_relative 'host_info'
require_relative '../monitoring/cluster_topology_monitor'

module AwsRubyDatabaseDriverWrapper
  module Host
    # Dynamic host list provider for RDS/Aurora clusters.
    # Manages topology cache reads and lazily creates a ClusterTopologyMonitor
    # to keep the topology up to date in the background.
    class RdsHostListProvider
      include Logging

      TOPOLOGY_CACHE_NAME = :topology
      DEFAULT_TOPOLOGY_QUERY_TIMEOUT_SEC = 5.0
      MONITOR_EXPIRATION_TIMEOUT_SEC = 900.0 # 15 minutes

      attr_reader :cluster_id, :instance_template, :rds_url_type

      # @param service_container [Services::ServiceContainer]
      # @param topology_utils [Object] responds to #query_topology
      def initialize(service_container:, topology_utils:)
        @service_container = service_container
        @topology_utils = topology_utils

        props = @service_container.connection_service.wrapper_props
        @cluster_id = PropertyDefinition::CLUSTER_ID.get_string(props)
        @instance_template = build_instance_template(props)
        validate_host_pattern!(@instance_template.host)
        @rds_url_type = Utils::RdsUtils.identify_rds_type(initial_host_info.host)

        prefixed_wrapper_config = @service_container.connection_service.prefixed_wrapper_config[PropertyDefinition::TOPOLOGY_MONITORING_PREFIX]
        @monitoring_wrapper_props = build_monitoring_wrapper_props(prefixed_wrapper_config || ::Concurrent::Map.new)
        prefixed_driver_config = @service_container.connection_service.prefixed_driver_config[PropertyDefinition::TOPOLOGY_MONITORING_PREFIX]
        @monitoring_driver_props = build_monitoring_driver_props(prefixed_driver_config || ::Concurrent::Map.new)

        register_monitor_type
        register_topology_cache
      end

      # Returns cached topology, otherwise starts the topology monitor in the background and
      # returns immediately without waiting for a fetch. Initial connections must not block on
      # topology being available; the monitor warms the cache for subsequent connections. Callers
      # that explicitly want to wait use force_refresh with a positive timeout.
      #
      # @return [Array<HostInfo>]
      def refresh
        stored = stored_topology
        return stored unless stored.nil? || stored.empty?

        return initial_host_list unless @service_container.dialect_service.dialect_final?

        hosts = force_refresh(false, 0.0)
        return hosts unless hosts.nil? || hosts.empty?

        stored_topology || initial_host_list
      end

      # Forces monitor to fetch fresh topology.
      # @param verify_writer [Boolean]
      # @param timeout_sec [Float]
      # @return [Array<HostInfo>, nil]
      def force_refresh(verify_writer, timeout_sec)
        return initial_host_list unless @service_container.dialect_service.dialect_final?

        monitor = @service_container.monitor_service.run_if_absent(:cluster_topology, @cluster_id, @service_container) do |_sc|
          Monitoring::ClusterTopologyMonitor.new(
            service_container: @service_container,
            cluster_id: @cluster_id,
            instance_template: @instance_template,
            topology_utils: @topology_utils,
            monitoring_driver_props: @monitoring_driver_props,
            monitoring_wrapper_props: @monitoring_wrapper_props
          )
        end
        monitor.force_refresh(verify_writer, timeout_sec)
      rescue Timeout::Error
        nil
      end

      # Stops the topology monitor for this cluster.
      def stop_monitor
        @service_container.monitor_service.stop_and_remove(:cluster_topology, @cluster_id)
      end

      private

      def stored_topology
        @service_container.storage_service.get(TOPOLOGY_CACHE_NAME, @cluster_id, register_access: true)
      end

      def initial_host_list
        [initial_host_info]
      end

      # --- Construction helpers ---

      def build_instance_template(props)
        pattern = PropertyDefinition::CLUSTER_INSTANCE_HOST_PATTERN.get(props)
        if pattern
          host, port = parse_host_port_pattern(pattern)
          port ||= initial_host_info.port
          HostInfo.new(host: host, port: port)
        else
          auto_pattern = Utils::RdsUtils.rds_instance_host_pattern(initial_host_info.host)
          HostInfo.new(host: auto_pattern, port: initial_host_info.port)
        end
      end

      def parse_host_port_pattern(pattern)
        last_colon = pattern.rindex(':')
        return [pattern, nil] if last_colon.nil?

        possible_port = pattern[(last_colon + 1)..]
        if possible_port.match?(/\A\d+\z/)
          [pattern[0...last_colon], possible_port]
        else
          [pattern, nil]
        end
      end

      # Splits prefixed overrides into driver-level and wrapper-level props.
      # Driver overrides are merged onto base driver_props with defaults applied.
      # @return Hash monitoring_driver_props
      def build_monitoring_driver_props(prefixed_driver_props)
        monitoring_driver_props = @service_container.connection_service.driver_props.dup

        prefixed_driver_props.each do |key, value|
          monitoring_driver_props[key] = value
        end

        monitoring_driver_props
      end

      # Driver overrides are merged onto base wrapper_props with defaults applied.
      # @return Hash monitoring_wrapper_props
      def build_monitoring_wrapper_props(prefixed_wrapper_props)
        monitoring_wrapper_props = @service_container.connection_service.wrapper_props.dup

        prefixed_wrapper_props.each do |key, value|
          monitoring_wrapper_props[key] = value
        end

        monitoring_wrapper_props
      end

      def validate_host_pattern!(pattern)
        raise Errors::AwsError, "Invalid cluster instance host pattern: '#{pattern}'" unless Utils::RdsUtils.dns_pattern_valid?(pattern)

        url_type = Utils::RdsUtils.identify_rds_type(pattern)
        if [Utils::RdsUrlType::RDS_PROXY, Utils::RdsUrlType::RDS_PROXY_ENDPOINT].include?(url_type)
          raise Errors::AwsError, "clusterInstanceHostPattern is not supported for RDS Proxy: '#{pattern}'"
        end

        return unless url_type == Utils::RdsUrlType::RDS_CUSTOM_CLUSTER

        raise Errors::AwsError, "clusterInstanceHostPattern is not supported for RDS Custom Clusters: '#{pattern}'"
      end

      def register_monitor_type
        @service_container.monitor_service.register_type(
          :cluster_topology,
          expiration_timeout_sec: MONITOR_EXPIRATION_TIMEOUT_SEC,
          produced_data_type: TOPOLOGY_CACHE_NAME
        )
      end

      def register_topology_cache
        @service_container.storage_service.register(TOPOLOGY_CACHE_NAME, ttl: 300)
      end

      def initial_host_info
        @service_container.connection_service.initial_host_info
      end
    end
  end
end
