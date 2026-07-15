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
require_relative '../errors'
require_relative '../host/host_role'
require_relative '../host/host_availability'
require_relative '../logging'
require_relative '../property_definition'
require_relative '../utils/accessible_regions'
require_relative '../utils/rds_utils'
require_relative '../utils/rds_url_type'

module AwsRubyDatabaseDriverWrapper
  module Plugins
    class InitialConnectionStrategyPlugin
      include Logging

      SUBSCRIBED_METHODS = Set['connect'].freeze

      SUBSTITUTION_STRATEGIES = {
        'writer' => :substitute_writer,
        'reader' => :substitute_reader,
        'any' => :substitute_any,
        'none' => :none
      }.freeze

      VERIFY_ROLES = {
        'writer' => :writer,
        'reader' => :reader,
        'none' => nil
      }.freeze

      attr_reader :subscribed_methods

      def initialize(service_container, props = ::Concurrent::Map.new)
        @service_container = service_container
        @props = props

        @retry_timeout_sec = PropertyDefinition::INITIAL_CONNECTION_RETRY_TIMEOUT_MS.get_int(props) / 1000.0
        @retry_interval_sec = PropertyDefinition::INITIAL_CONNECTION_RETRY_INTERVAL_MS.get_int(props) / 1000.0
        @wait_for_topology_sec = PropertyDefinition::INITIAL_CONNECTION_WAIT_FOR_TOPOLOGY_MS.get_int(props) / 1000.0
        @host_selector_strategy = PropertyDefinition::INITIAL_CONNECTION_HOST_SELECTOR_STRATEGY.get(props)
        @accessible_regions = Utils::AccessibleRegions.parse(props)
        @subscribed_methods = SUBSCRIBED_METHODS
      end

      def connect(host_info, driver_props, is_initial_connection, pipeline_callable)
        return pipeline_callable.call unless is_initial_connection

        host = host_info&.host
        url_type = Utils::RdsUtils.identify_rds_type(host)
        substitution_strategy = determine_substitution_strategy(host, url_type)
        role_to_verify = determine_role_to_verify(host, url_type)

        connect_with_retry(host_info, url_type, substitution_strategy, role_to_verify, driver_props, pipeline_callable)
      end

      private

      def connect_with_retry(host_info, url_type, substitution_strategy, role_to_verify, driver_props, pipeline_callable)
        deadline = monotonic_time + @retry_timeout_sec
        conn = nil

        begin
          while monotonic_time < deadline
            candidate_host = resolve_candidate_host(host_info, url_type, substitution_strategy)

            begin
              conn = open_connection_to(
                candidate_host, host_info, substitution_strategy, driver_props, pipeline_callable
              )

              if conn.nil?
                sleep(@retry_interval_sec)
                next
              end

              if role_to_verify.nil?
                result = conn
                conn = nil
                return result
              end

              conn_role = dialect_service.db_dialect.host_role(conn)
              if conn_role == role_to_verify
                result = conn
                conn = nil
                return result
              end

              host_service.force_refresh_host_list
              if role_to_verify == Host::HostRole::READER && !readers_in_topology?(host_service.all_hosts)
                logger.warn('Reader verification expected but no readers exist in topology; accepting connection with writer role')
                result = conn
                conn = nil
                return result
              end

              logger.debug("Connection to #{candidate_host&.host} has role #{conn_role}, expected #{role_to_verify}; retrying")
              close_connection(conn)
              conn = nil
              sleep(@retry_interval_sec)
            rescue StandardError => e
              close_connection(conn)
              conn = nil

              raise if dialect_service.login_error?(e)

              if dialect_service.network_error?(e)
                host_service.set_availability(candidate_host, Host::HostAvailability::UNAVAILABLE) if candidate_host
                next
              end

              next if dialect_service.read_only_error?(e) && substitution_strategy == :substitute_writer

              raise
            end
          end
        ensure
          close_connection(conn)
        end

        raise Errors::AwsError,
              "Initial connection strategy timed out after #{(@retry_timeout_sec * 1000).to_i}ms. " \
              "Substitution: #{substitution_strategy}, verification: #{role_to_verify}"
      end

      def resolve_candidate_host(original_host_info, url_type, substitution_strategy)
        return original_host_info if substitution_strategy == :none

        candidate = select_candidate_host(original_host_info, url_type, substitution_strategy)

        return candidate if candidate && Utils::RdsUtils.rds_instance?(candidate.host)

        # Topology not available — try waiting if configured
        if @wait_for_topology_sec.positive? && host_service.all_hosts.empty?
          host_service.force_refresh_host_list(timeout_sec: @wait_for_topology_sec)
          candidate = select_candidate_host(original_host_info, url_type, substitution_strategy)
          return candidate if candidate && Utils::RdsUtils.rds_instance?(candidate.host)
        end

        # Fall back to original host
        original_host_info
      end

      def open_connection_to(candidate_host, original_host_info, substitution_strategy, driver_props, pipeline_callable)
        if substitution_strategy == :none || candidate_host == original_host_info
          conn = pipeline_callable.call
          # Refresh topology in background when connecting via cluster endpoint
          host_service.force_refresh_host_list if substitution_strategy != :none
          return conn
        end

        plugin_manager.internal_connect(candidate_host, driver_props, {}, false)
      end

      def determine_substitution_strategy(host, url_type)
        explicit_value = PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.get(@props)

        if explicit_value
          strategy = parse_substitution_value(explicit_value)
          validate_substitution_strategy(strategy, url_type)
          return strategy
        end

        case url_type
        when Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
          :substitute_writer
        when Utils::RdsUrlType::RDS_WRITER_CLUSTER
          resolve_writer_cluster_substitution(host)
        when Utils::RdsUrlType::RDS_READER_CLUSTER
          :substitute_reader
        else
          :none
        end
      end

      def determine_role_to_verify(host, url_type)
        explicit_value = PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.get(@props)

        if explicit_value
          role = parse_verify_role_value(explicit_value)
          validate_verify_role(role, url_type)
          return role
        end

        case url_type
        when Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
          Host::HostRole::WRITER
        when Utils::RdsUrlType::RDS_WRITER_CLUSTER
          resolve_writer_cluster_verification(host)
        when Utils::RdsUrlType::RDS_READER_CLUSTER
          Host::HostRole::READER
        end
      end

      def select_candidate_host(original_host_info, url_type, substitution_strategy)
        return original_host_info if substitution_strategy == :none

        all_hosts = host_service.all_hosts
        return nil if all_hosts.empty?

        if substitution_strategy == :substitute_writer
          filtered = Utils::AccessibleRegions.filter_by_region(all_hosts, @accessible_regions)
          return filtered.find { |h| h.role == Host::HostRole::WRITER }
        end

        target_role = case substitution_strategy
                      when :substitute_reader then Host::HostRole::READER
                      end

        available_hosts = Utils::AccessibleRegions.filter_by_region(host_service.hosts, @accessible_regions)

        endpoint_region = url_type_has_region?(url_type) ? Utils::RdsUtils.rds_region(original_host_info.host) : nil
        if endpoint_region
          available_hosts = available_hosts.select do |h|
            Utils::RdsUtils.rds_region(h.host)&.casecmp(endpoint_region)&.zero?
          end
        end

        host_service.select_host(available_hosts, target_role, @host_selector_strategy)
      rescue StandardError
        nil
      end

      def resolve_writer_cluster_substitution(host)
        writer = find_writer_in_topology
        return :none if writer.nil? || !Utils::RdsUtils.rds_instance?(writer.host)

        if Utils::RdsUtils.same_region?(writer.host, host)
          :substitute_writer
        else
          parse_substitution_value(
            PropertyDefinition::INITIAL_CONNECTION_INACTIVE_SUBSTITUTE_HOST.get(@props)
          )
        end
      end

      def resolve_writer_cluster_verification(host)
        writer = find_writer_in_topology
        if writer && Utils::RdsUtils.rds_instance?(writer.host) && Utils::RdsUtils.same_region?(writer.host, host)
          return Host::HostRole::WRITER
        end

        inactive_value = PropertyDefinition::INITIAL_CONNECTION_INACTIVE_VERIFY_ROLE.get(@props)
        parse_verify_role_value(inactive_value)
      end

      def find_writer_in_topology
        host_service.all_hosts.find { |h| h.role == Host::HostRole::WRITER }
      end

      def parse_substitution_value(value)
        normalized = value.to_s.downcase
        strategy = SUBSTITUTION_STRATEGIES[normalized]
        unless strategy
          raise Errors::AwsError,
                "Invalid #{PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.name} value: '#{value}'. " \
                "Valid values: #{SUBSTITUTION_STRATEGIES.keys.join(', ')}"
        end
        strategy
      end

      def parse_verify_role_value(value)
        normalized = value.to_s.downcase
        unless VERIFY_ROLES.key?(normalized)
          raise Errors::AwsError,
                "Invalid #{PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.name} value: '#{value}'. " \
                "Valid values: #{VERIFY_ROLES.keys.join(', ')}"
        end
        VERIFY_ROLES[normalized]
      end

      def validate_substitution_strategy(strategy, url_type)
        return if strategy == :none

        if url_type == Utils::RdsUrlType::RDS_INSTANCE
          raise Errors::AwsError,
                "#{PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.name} cannot be set when connecting to an instance endpoint"
        end

        if strategy == :substitute_writer &&
           [Utils::RdsUrlType::RDS_READER_CLUSTER, Utils::RdsUrlType::RDS_CUSTOM_CLUSTER].include?(url_type)
          raise Errors::AwsError,
                "#{PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.name}: 'writer' is invalid for reader or custom cluster endpoints"
        end

        if strategy == :substitute_reader &&
           [Utils::RdsUrlType::RDS_WRITER_CLUSTER, Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER].include?(url_type)
          raise Errors::AwsError,
                "#{PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.name}: 'reader' is invalid for writer or global cluster endpoints"
        end

        return unless strategy == :substitute_any && url_type != Utils::RdsUrlType::RDS_CUSTOM_CLUSTER

        raise Errors::AwsError,
              "#{PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.name}: 'any' is only valid for custom cluster endpoints"
      end

      def validate_verify_role(role, url_type)
        return if role.nil?

        if role == Host::HostRole::READER &&
           [Utils::RdsUrlType::RDS_WRITER_CLUSTER, Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER].include?(url_type)
          raise Errors::AwsError,
                "#{PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.name}: 'reader' is invalid for writer or global cluster endpoints"
        end

        return unless role == Host::HostRole::WRITER && url_type == Utils::RdsUrlType::RDS_READER_CLUSTER

        raise Errors::AwsError,
              "#{PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.name}: 'writer' is invalid for reader cluster endpoints"
      end

      def readers_in_topology?(hosts)
        return false if hosts.nil? || hosts.empty?

        hosts.any? { |h| h.role == Host::HostRole::READER }
      end

      def url_type_has_region?(url_type)
        [
          Utils::RdsUrlType::RDS_WRITER_CLUSTER,
          Utils::RdsUrlType::RDS_READER_CLUSTER,
          Utils::RdsUrlType::RDS_CUSTOM_CLUSTER,
          Utils::RdsUrlType::RDS_INSTANCE,
          Utils::RdsUrlType::RDS_PROXY,
          Utils::RdsUrlType::RDS_PROXY_ENDPOINT
        ].include?(url_type)
      end

      def close_connection(conn)
        return if conn.nil?

        if conn.respond_to?(:close)
          conn.close
        elsif conn.respond_to?(:finish)
          conn.finish
        end
      rescue StandardError
        # Ignore errors when closing a connection during cleanup
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def host_service
        @service_container.host_service
      end

      def dialect_service
        @service_container.dialect_service
      end

      def plugin_manager
        @service_container.plugin_manager
      end
    end
  end
end
