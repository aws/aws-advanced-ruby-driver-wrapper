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

module AwsAdvancedRubyDriverWrapper
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
        'none' => :none
      }.freeze

      attr_reader :subscribed_methods

      def initialize(service_container, props = ::Concurrent::Map.new)
        @service_container = service_container

        @retry_timeout_sec = PropertyDefinition::INITIAL_CONNECTION_RETRY_TIMEOUT_MS.get_int(props) / 1000.0
        @retry_interval_sec = PropertyDefinition::INITIAL_CONNECTION_RETRY_INTERVAL_MS.get_int(props) / 1000.0
        @wait_for_topology_sec = PropertyDefinition::INITIAL_CONNECTION_WAIT_FOR_TOPOLOGY_MS.get_int(props) / 1000.0
        @host_selector_strategy = PropertyDefinition::INITIAL_CONNECTION_HOST_SELECTOR_STRATEGY.get(props)
        @accessible_regions = Utils::AccessibleRegions.parse(props)
        @subscribed_methods = SUBSCRIBED_METHODS

        parse_role_props(props)
      end

      def connect(host_info, driver_props, is_initial_connection, pipeline_callable)
        return pipeline_callable.call unless is_initial_connection

        host = host_info&.host
        url_type = Utils::RdsUtils.identify_rds_type(host)

        # Wait for the cluster topology to be discovered before deciding, if the caller opted in.
        wait_for_topology_if_configured if cluster_url?(url_type)

        # Classify a plain writer cluster URL as single-region, global-active, global-inactive, or unresolved.
        classification = url_type == Utils::RdsUrlType::RDS_WRITER_CLUSTER ? classify_writer_cluster(host) : nil
        substitution_strategy = determine_substitution_strategy(url_type, classification)
        role_to_verify = determine_role_to_verify(url_type, classification, substitution_strategy)

        # Only cluster-type endpoints are candidates for substitution/verification. Anything else
        # (instance, proxy, IP, custom domain, ...) connects directly to the provided URL.
        return pipeline_callable.call unless cluster_url?(url_type)

        connect_with_retry(host_info, url_type, substitution_strategy, role_to_verify, driver_props, pipeline_callable)
      end

      private

      def connect_with_retry(host_info, url_type, substitution_strategy, role_to_verify, driver_props, pipeline_callable)
        deadline = monotonic_time + @retry_timeout_sec
        conn = nil
        success = false

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
                success = true
                return conn
              end

              conn_role = dialect_service.db_dialect.host_role(conn)
              if conn_role == role_to_verify
                success = true
                return conn
              end

              host_service.force_refresh_host_list?
              if role_to_verify == Host::HostRole::READER && !readers_in_topology?(host_service.all_hosts)
                logger.warn('Reader verification expected but no readers exist in topology; accepting connection with writer role')
                success = true
                return conn
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
          close_connection(conn) unless success
        end

        raise Errors::AwsError,
              "Initial connection strategy timed out after #{(@retry_timeout_sec * 1000).to_i}ms. " \
              "Substitution: #{substitution_strategy}, verification: #{role_to_verify}"
      end

      def resolve_candidate_host(original_host_info, url_type, substitution_strategy)
        return original_host_info if substitution_strategy == :none

        candidate = select_candidate_host(original_host_info, url_type, substitution_strategy)
        return candidate if candidate && Utils::RdsUtils.rds_instance?(candidate.host)

        # No instance URL available to substitute. This happens when topology hasn't been successfully queried yet.
        # Fall back to connecting via the initial endpoint.
        # Callers that want to wait for topology first opt in via INITIAL_CONNECTION_WAIT_FOR_TOPOLOGY_MS (handled in #connect).
        logger.debug("Unable to resolve a substitute instance host for strategy '#{substitution_strategy}'; \
          connecting via the original endpoint '#{original_host_info&.host}'")
        original_host_info
      end

      # When INITIAL_CONNECTION_WAIT_FOR_TOPOLOGY_MS is positive and only the initial (non-instance)
      # endpoint is known, block up to the timeout for the topology monitor to discover instance URLs
      # before making substitution/verification decisions. Limitation: force_refresh_host_list returns
      # the initial host list when the dialect is not final, so topology may still be unavailable after waiting.
      def wait_for_topology_if_configured
        return unless @wait_for_topology_sec.positive?
        return unless only_initial_endpoint_known?

        host_service.force_refresh_host_list?(timeout_sec: @wait_for_topology_sec)
      end

      # True when the topology contains a single host that is not an instance URL, i.e. we only have
      # the initial connection endpoint and the topology has not been queried yet.
      def only_initial_endpoint_known?
        hosts = host_service.all_hosts
        hosts.size <= 1 && hosts.none? { |h| Utils::RdsUtils.rds_instance?(h.host) }
      end

      # True once real topology has been discovered: more than one host, or a single instance URL.
      def topology_available?
        hosts = host_service.all_hosts
        return false if hosts.empty?

        hosts.size > 1 || Utils::RdsUtils.rds_instance?(hosts.first.host)
      end

      def open_connection_to(candidate_host, original_host_info, substitution_strategy, driver_props, pipeline_callable)
        if substitution_strategy == :none || candidate_host == original_host_info
          conn = pipeline_callable.call
          # Refresh topology in background when connecting via cluster endpoint
          host_service.force_refresh_host_list? if substitution_strategy != :none
          return conn
        end

        plugin_manager.connect(candidate_host, driver_props, true, plugin_to_skip: self)
      end

      # A writer cluster URL falls into one of these buckets, decided by the dialect first
      # (authoritative) and topology second (only to split active vs inactive within a global cluster):
      #   :single_region - dialect is final and not global -> connected to the writer's own cluster
      #   :global_active - global dialect, topology shows the writer is in this endpoint's region
      #   :global_inactive - global dialect, topology shows the writer is in another region
      #   :unresolved - dialect not final, or global but topology can't tell us which cluster this is
      def classify_writer_cluster(host)
        return :unresolved unless dialect_service.dialect_final?
        return :single_region unless dialect_service.db_dialect.global?

        # Global cluster: use the confirmed cross-region topology to locate the writer.
        return :unresolved unless topology_available?

        writer = find_writer_in_topology
        return :unresolved if writer.nil? || !Utils::RdsUtils.rds_instance?(writer.host)

        Utils::RdsUtils.same_region?(writer.host, host) ? :global_active : :global_inactive
      end

      def determine_substitution_strategy(url_type, classification)
        # @explicit_substitution was parsed at init; only the URL-dependent validity is checked here.
        if @explicit_substitution
          validate_substitution_strategy(@explicit_substitution, url_type)
          return @explicit_substitution
        end

        case url_type
        when Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
          :substitute_writer
        when Utils::RdsUrlType::RDS_WRITER_CLUSTER
          writer_cluster_substitution(classification)
        when Utils::RdsUrlType::RDS_READER_CLUSTER
          :substitute_reader
        else
          :none
        end
      end

      def determine_role_to_verify(url_type, classification, substitution_strategy)
        role = resolve_verify_role(url_type, classification, substitution_strategy)

        # :none is the explicit "skip verification" sentinel; normalize it to nil, which
        # connect_with_retry treats as "no role to verify".
        role == :none ? nil : role
      end

      def resolve_verify_role(url_type, classification, substitution_strategy)
        # @explicit_verify_role was parsed at init; only the URL-dependent validity is checked here.
        if @explicit_verify_role
          validate_verify_role(@explicit_verify_role, url_type)
          return @explicit_verify_role
        end

        case url_type
        when Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER
          Host::HostRole::WRITER
        when Utils::RdsUrlType::RDS_WRITER_CLUSTER
          writer_cluster_verification(classification, substitution_strategy)
        when Utils::RdsUrlType::RDS_READER_CLUSTER
          Host::HostRole::READER
        end
      end

      def writer_cluster_substitution(classification)
        case classification
        when :single_region, :global_active
          :substitute_writer
        when :global_inactive
          # INITIAL_CONNECTION_INACTIVE_SUBSTITUTE_HOST governs inactive cluster endpoints. When unset,
          # pass the endpoint through untouched. Users who want cross-region writer substitution must opt in explicitly.
          @inactive_substitution || :none
        else
          # :unresolved - we don't know enough to substitute safely; connect via the original endpoint.
          :none
        end
      end

      def writer_cluster_verification(classification, substitution_strategy)
        case classification
        when :single_region, :global_active
          Host::HostRole::WRITER
        when :global_inactive
          # INITIAL_CONNECTION_INACTIVE_VERIFY_ROLE takes priority when set. When unset, verify writer only if we substituted
          # a writer, which only happens when the user opted into substitution explicitly via INITIAL_CONNECTION_SUBSTITUTE_HOST
          # or INITIAL_CONNECTION_INACTIVE_SUBSTITUTE_HOST. Otherwise, do not verify role.
          if @inactive_verify_role
            @inactive_verify_role
          elsif substitution_strategy == :substitute_writer
            Host::HostRole::WRITER
          end
        end
        # :unresolved -> nil (no verification)
      end

      def select_candidate_host(original_host_info, url_type, substitution_strategy)
        return original_host_info if substitution_strategy == :none

        all_hosts = host_service.all_hosts
        return nil if all_hosts.empty?

        if substitution_strategy == :substitute_writer
          filtered = Utils::AccessibleRegions.filter_by_region(all_hosts, @accessible_regions)
          return filtered.find { |h| h.role == Host::HostRole::WRITER }
        end

        target_role = substitution_strategy == :substitute_reader ? Host::HostRole::READER : nil

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

      def find_writer_in_topology
        host_service.all_hosts.find { |h| h.role == Host::HostRole::WRITER }
      end

      # Cluster-type endpoints are the only ones eligible for substitution/verification.
      def cluster_url?(url_type)
        [
          Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER,
          Utils::RdsUrlType::RDS_WRITER_CLUSTER,
          Utils::RdsUrlType::RDS_READER_CLUSTER,
          Utils::RdsUrlType::RDS_CUSTOM_CLUSTER
        ].include?(url_type)
      end

      # Parse the substitution/verification props up front so a malformed value  fails fast at wrapper construction.
      # URL-dependent validity (e.g. 'writer' on a reader cluster) will checked in #connect.
      # An unset prop parses to nil, an explicit 'none' parses to :none.
      def parse_role_props(props)
        raw_substitution = PropertyDefinition::INITIAL_CONNECTION_SUBSTITUTE_HOST.get(props)
        @explicit_substitution = raw_substitution && parse_substitution_value(raw_substitution)

        raw_verify_role = PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.get(props)
        @explicit_verify_role = raw_verify_role && parse_verify_role_value(raw_verify_role)

        raw_inactive_substitution = PropertyDefinition::INITIAL_CONNECTION_INACTIVE_SUBSTITUTE_HOST.get(props)
        @inactive_substitution = raw_inactive_substitution && parse_inactive_substitution_value(raw_inactive_substitution)

        raw_inactive_verify_role = PropertyDefinition::INITIAL_CONNECTION_INACTIVE_VERIFY_ROLE.get(props)
        @inactive_verify_role = raw_inactive_verify_role && parse_inactive_verify_role_value(raw_inactive_verify_role)
      end

      def parse_inactive_substitution_value(value)
        strategy = parse_substitution_value(value)
        return strategy if %i[substitute_writer none].include?(strategy)

        raise Errors::AwsError,
              "#{PropertyDefinition::INITIAL_CONNECTION_INACTIVE_SUBSTITUTE_HOST.name}: '#{value}' is not valid. " \
              "Valid values are 'writer' or 'none'."
      end

      def parse_inactive_verify_role_value(value)
        role = parse_verify_role_value(value)
        return role if [Host::HostRole::WRITER, :none].include?(role)

        raise Errors::AwsError,
              "#{PropertyDefinition::INITIAL_CONNECTION_INACTIVE_VERIFY_ROLE.name}: '#{value}' is not valid. " \
              "Valid values are 'writer' or 'none'."
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
        return if role.nil? || role == :none

        if role == Host::HostRole::READER &&
           [Utils::RdsUrlType::RDS_WRITER_CLUSTER, Utils::RdsUrlType::RDS_GLOBAL_WRITER_CLUSTER].include?(url_type)
          raise Errors::AwsError,
                "#{PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.name}: 'reader' is invalid for writer or global cluster endpoints"
        end

        # A custom endpoint can only be of type 'reader' or 'any', so writer verification is not allowed.
        return unless role == Host::HostRole::WRITER &&
                      [Utils::RdsUrlType::RDS_READER_CLUSTER, Utils::RdsUrlType::RDS_CUSTOM_CLUSTER].include?(url_type)

        raise Errors::AwsError,
              "#{PropertyDefinition::INITIAL_CONNECTION_VERIFY_ROLE.name}: 'writer' is invalid for reader or custom cluster endpoints"
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

        dialect_service.driver_dialect.close_connection(conn)
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
